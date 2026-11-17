# Mantiene abierta una conexion a SQL Server / Azure SQL y ejecuta las consultas que aparecen en su cola.
# La contrasena la escribe el usuario una sola vez al arrancar y solo vive en memoria (SecureString).
# Por defecto solo admite lecturas. Con -AllowWrites admite tambien escrituras, salvo con el usuario
# ai-data-reader, que siempre queda en solo lectura.
# Cola por defecto: %USERPROFILE%\.sql-broker\<servidor>\<base de datos>\<usuario>\
#   inbox\<nombre>.sql            -> consulta pendiente
#   results\<nombre>.csv          -> filas devueltas (run-query.ps1 lo borra al leerlo; el broker purga los que queden)
#   results\<nombre>.status.txt   -> "OK <n> filas", "OK <n> filas afectadas" o "ERROR <mensaje>"
#   ready.txt                     -> existe mientras el broker esta conectado (PID, hora, modo, clasificacion)
# Controles (ENS): lista blanca de solo lectura, clasificacion de columnas sensibles, registro de actividad en
# %USERPROFILE%\.sql-broker\_audit, cierre por inactividad y purga de resultados.
param(
    [Parameter(Mandatory)][string]$Server,
    [Parameter(Mandatory)][string]$Database,
    [Parameter(Mandatory)][string]$User,
    [switch]$AllowWrites,
    [int]$MaxRows = 1000,
    [int]$CommandTimeout = 120,
    [int]$IdleMinutes = -1,            # -1 = 30 min en lectura, 10 min en escritura; 0 = sin cierre (no recomendado)
    [int]$ResultRetentionHours = 2,    # los resultados que nadie recoja se borran pasado este tiempo
    [string]$QueueDir
)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Data
. (Join-Path $PSScriptRoot 'sql-broker-lib.ps1')

$readOnly = (-not $AllowWrites) -or ($User -eq 'ai-data-reader')
if ($AllowWrites -and $readOnly) { Write-Host 'Aviso: ai-data-reader es un usuario de solo lectura; se ignora -AllowWrites.' }
$mode = if ($readOnly) { 'SOLO LECTURA' } else { 'LECTURA Y ESCRITURA' }
if ($IdleMinutes -lt 0) { $IdleMinutes = if ($readOnly) { 30 } else { 10 } }

if (-not $QueueDir) { $QueueDir = Join-Path $env:USERPROFILE ".sql-broker\$Server\$Database\$User" }
$inbox   = Join-Path $QueueDir 'inbox'
$results = Join-Path $QueueDir 'results'
$ready   = Join-Path $QueueDir 'ready.txt'
New-Item -ItemType Directory -Force $inbox, $results | Out-Null

# Clasificacion de columnas sensibles (si existe y esta revisada se aplica; si el fichero esta roto, no se arranca)
try { $classification = Get-Classification $Server $Database }
catch { throw "El fichero de clasificacion de $Server/$Database no se puede leer: $($_.Exception.Message). Corrijalo o muevalo y reintente." }
$maskNames = Get-SensitiveColumnNames $classification
$classText = if (-not $classification) { 'ninguna (ejecute scan-schema.ps1 y revise el resultado)' }
             elseif (-not $classification.reviewed) { 'pendiente de revisar (no se aplica)' }
             else { "aplicada: $(@($classification.sensitive).Count) entradas" }

# Contrasena: primero se busca la credencial generica "sql-broker:<servidor>:<usuario>" del Administrador
# de credenciales de Windows; se lee dentro de este proceso como SecureString y nunca se imprime.
# Si no existe, se pide por teclado como siempre.
if (-not ('SqlBrokerCred' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
using System.Security;
public static class SqlBrokerCred {
    [DllImport("advapi32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    static extern bool CredRead(string target, int type, int flags, out IntPtr cred);
    [DllImport("advapi32.dll")]
    static extern void CredFree(IntPtr cred);
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    struct CRED {
        public int Flags; public int Type; public string TargetName; public string Comment;
        public long LastWritten; public int BlobSize; public IntPtr Blob; public int Persist;
        public int AttributeCount; public IntPtr Attributes; public string TargetAlias; public string UserName;
    }
    public static SecureString Read(string target) {
        IntPtr p;
        if (!CredRead(target, 1, 0, out p)) return null;
        try {
            CRED c = (CRED)Marshal.PtrToStructure(p, typeof(CRED));
            SecureString s = new SecureString();
            for (int i = 0; i < c.BlobSize / 2; i++) s.AppendChar((char)Marshal.ReadInt16(c.Blob, i * 2));
            return s;
        } finally { CredFree(p); }
    }
}
'@
}
$credTarget = "sql-broker:${Server}:${User}"
$password = [SqlBrokerCred]::Read($credTarget)
if ($password -and $password.Length -gt 0) {
    Write-Host "Usando la credencial guardada '$credTarget' del Administrador de credenciales."
} else {
    Write-Host "No hay credencial guardada '$credTarget'; se pide la contrasena."
    $password = Read-Host "Contrasena de $User" -AsSecureString
}
$password.MakeReadOnly()
$credential = New-Object System.Data.SqlClient.SqlCredential($User, $password)
$connectionString = "Server=tcp:$Server,1433;Database=$Database;Encrypt=True;TrustServerCertificate=False;Connect Timeout=30;Pooling=False;Application Name=sql-broker"

function Open-Connection {
    $c = New-Object System.Data.SqlClient.SqlConnection($connectionString, $credential)
    $c.Open()
    $c
}

function Invoke-Query([string]$sql) {
    $cmd = $script:conn.CreateCommand()
    $cmd.CommandText = $sql
    $cmd.CommandTimeout = $CommandTimeout
    $reader = $cmd.ExecuteReader()
    try {
        $table = New-Object System.Data.DataTable
        for ($i = 0; $i -lt $reader.FieldCount; $i++) {
            # Columnas sin nombre o repetidas reciben un nombre unico
            $col = $reader.GetName($i)
            if ([string]::IsNullOrWhiteSpace($col) -or $table.Columns.Contains($col)) { $col = "col$($i + 1)" }
            [void]$table.Columns.Add($col)
        }
        $values = New-Object object[] $reader.FieldCount
        while ($table.Rows.Count -lt $MaxRows -and $reader.Read()) {
            [void]$reader.GetValues($values)
            [void]$table.Rows.Add($values)
        }
    } finally {
        $reader.Close()
    }
    # RecordsAffected solo es fiable con el lector cerrado; -1 en un SELECT
    $table.ExtendedProperties['RecordsAffected'] = $reader.RecordsAffected
    ,$table
}

function Remove-OldResults {
    $limit = (Get-Date).AddHours(-$ResultRetentionHours)
    Get-ChildItem $results -File -ErrorAction SilentlyContinue | Where-Object { $_.LastWriteTime -lt $limit } | Remove-Item -Force -ErrorAction SilentlyContinue
}

function Limit-Text([string]$t, [int]$max) { if ($t.Length -gt $max) { $t.Substring(0, $max) + '...' } else { $t } }

Remove-OldResults
$script:conn = Open-Connection
$idleText = if ($IdleMinutes -gt 0) { "$IdleMinutes min" } else { 'desactivado' }
Set-Content $ready "PID $PID`nConectado $(Get-Date -Format s) a $Database en $Server como $User`nModo $mode`nClasificacion $classText`nCierre por inactividad $idleText" -Encoding UTF8
Write-Host "Conectado a $Database en $Server como $User (modo $mode)."
Write-Host "Clasificacion de datos: $classText."
Write-Host "Cierre por inactividad: $idleText. Resultados no recogidos: se borran a las $ResultRetentionHours h."
Write-Host "Esperando consultas en $inbox (Ctrl-C para cerrar la conexion)."
Write-AuditEntry ([ordered]@{ event = 'start'; server = $Server; db = $Database; dbuser = $User; mode = $mode; pid = $PID; idleMinutes = $IdleMinutes; classification = $classText })

$lastActivity = Get-Date
$lastPurge = Get-Date
$stopReason = 'ctrl-c'
try {
    while ($true) {
        foreach ($file in Get-ChildItem $inbox -Filter *.sql | Sort-Object LastWriteTime) {
            $name = $file.BaseName
            $sql = Get-Content $file.FullName -Raw -Encoding UTF8
            Remove-Item $file.FullName
            $lastActivity = Get-Date
            $csvPath = Join-Path $results "$name.csv"
            $statusPath = Join-Path $results "$name.status.txt"
            $sw = [Diagnostics.Stopwatch]::StartNew()
            $outcome = 'ok'; $rowCount = $null; $message = ''
            try {
                if ($readOnly) {
                    $why = Test-ReadOnlySql $sql
                    if ($why) { $outcome = 'rejected'; throw "Consulta rechazada: este broker es de solo lectura ($why)." }
                }
                $why = Test-SensitiveReference $sql $classification
                if ($why) { $outcome = 'rejected'; throw "Consulta rechazada por la clasificacion de datos: $why. Si hace falta ese dato, hagalo usted en SSMS." }
                if ($script:conn.State -ne 'Open') { $script:conn.Dispose(); $script:conn = Open-Connection }
                try {
                    $table = Invoke-Query $sql
                } catch {
                    # La conexion puede haberse cortado por inactividad: se reabre y se reintenta una vez.
                    # Solo en modo lectura: una escritura podria haberse aplicado antes del corte.
                    if (-not $readOnly -or $script:conn.State -eq 'Open') { throw }
                    $script:conn.Dispose()
                    $script:conn = Open-Connection
                    $table = Invoke-Query $sql
                }
                # Segunda red: se ocultan las columnas del resultado cuyo nombre figura como sensible
                $masked = @($table.Columns | Where-Object { $maskNames -contains $_.ColumnName.ToLowerInvariant() } | ForEach-Object { $_.ColumnName })
                foreach ($m in $masked) { foreach ($r in $table.Rows) { $r[$m] = '[OCULTO]' } }
                $columns = @($table.Columns | ForEach-Object { $_.ColumnName })
                if ($columns.Count -gt 0) {
                    $table.Rows | Select-Object -Property $columns | Export-Csv $csvPath -NoTypeInformation -Encoding UTF8
                    $note = if ($table.Rows.Count -ge $MaxRows) { " (limitado a $MaxRows)" } else { '' }
                    $summary = "$($table.Rows.Count) filas$note"
                    $rowCount = $table.Rows.Count
                } else {
                    $affected = [Math]::Max(0, $table.ExtendedProperties['RecordsAffected'])
                    $summary = "$affected filas afectadas"
                    $rowCount = $affected
                }
                $lines = @("OK $summary")
                if ($masked.Count -gt 0) { $lines += "AVISO columnas ocultas por la clasificacion de datos: $($masked -join ', ')" }
                Set-Content $statusPath $lines -Encoding UTF8
                Write-Host "[$(Get-Date -Format HH:mm:ss)] $name -> $summary"
            } catch {
                if ($outcome -eq 'ok') { $outcome = 'error' }
                $message = $_.Exception.Message
                Set-Content $statusPath "ERROR $message" -Encoding UTF8
                Write-Host "[$(Get-Date -Format HH:mm:ss)] $name -> ERROR $message"
            }
            Write-AuditEntry ([ordered]@{
                event = 'query'; id = $name; server = $Server; db = $Database; dbuser = $User; mode = $mode
                outcome = $outcome; rows = $rowCount; ms = $sw.ElapsedMilliseconds
                sha256 = (Get-Sha256Hex $sql); sql = (Limit-Text $sql 4000); message = (Limit-Text $message 300)
            })
        }
        if (((Get-Date) - $lastPurge).TotalMinutes -ge 5) { Remove-OldResults; $lastPurge = Get-Date }
        if ($IdleMinutes -gt 0 -and ((Get-Date) - $lastActivity).TotalMinutes -ge $IdleMinutes) {
            $stopReason = "inactividad ($IdleMinutes min)"
            Write-Host "Sin consultas durante $IdleMinutes min: se cierra la conexion. Vuelva a arrancar el broker si hace falta."
            break
        }
        Start-Sleep -Milliseconds 500
    }
} finally {
    Remove-Item $ready -ErrorAction SilentlyContinue
    $script:conn.Dispose()
    Write-AuditEntry ([ordered]@{ event = 'stop'; server = $Server; db = $Database; dbuser = $User; reason = $stopReason })
    Write-Host 'Conexion cerrada.'
}
