# Mantiene abierta una conexion a SQL Server / Azure SQL y ejecuta las consultas que aparecen en su cola.
# La contrasena la escribe el usuario una sola vez al arrancar y solo vive en memoria (SecureString).
# Por defecto solo admite lecturas. Con -AllowWrites admite tambien escrituras, salvo con el usuario
# ai-data-reader, que siempre queda en solo lectura.
# Cola por defecto: %USERPROFILE%\.sql-broker\<servidor>\<base de datos>\<usuario>\
#   inbox\<nombre>.sql            -> consulta pendiente
#   results\<nombre>.csv          -> filas devueltas
#   results\<nombre>.status.txt   -> "OK <n> filas", "OK <n> filas afectadas" o "ERROR <mensaje>"
#   ready.txt                     -> existe mientras el broker esta conectado (PID, hora y modo)
param(
    [Parameter(Mandatory)][string]$Server,
    [Parameter(Mandatory)][string]$Database,
    [Parameter(Mandatory)][string]$User,
    [switch]$AllowWrites,
    [int]$MaxRows = 1000,
    [int]$CommandTimeout = 120,
    [string]$QueueDir
)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Data

$readOnly = (-not $AllowWrites) -or ($User -eq 'ai-data-reader')
if ($AllowWrites -and $readOnly) { Write-Host 'Aviso: ai-data-reader es un usuario de solo lectura; se ignora -AllowWrites.' }
$mode = if ($readOnly) { 'SOLO LECTURA' } else { 'LECTURA Y ESCRITURA' }

if (-not $QueueDir) { $QueueDir = Join-Path $env:USERPROFILE ".sql-broker\$Server\$Database\$User" }
$inbox   = Join-Path $QueueDir 'inbox'
$results = Join-Path $QueueDir 'results'
$ready   = Join-Path $QueueDir 'ready.txt'
New-Item -ItemType Directory -Force $inbox, $results | Out-Null

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

# Solo lecturas: rechaza cualquier sentencia que pueda modificar datos o esquema
$forbidden = '\b(INSERT|UPDATE|DELETE|MERGE|DROP|ALTER|CREATE|TRUNCATE|EXEC|EXECUTE|GRANT|REVOKE|DENY|BACKUP|RESTORE)\b'

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

$script:conn = Open-Connection
Set-Content $ready "PID $PID`nConectado $(Get-Date -Format s) a $Database en $Server como $User`nModo $mode" -Encoding UTF8
Write-Host "Conectado a $Database en $Server como $User (modo $mode)."
Write-Host "Esperando consultas en $inbox (Ctrl-C para cerrar la conexion)."

try {
    while ($true) {
        foreach ($file in Get-ChildItem $inbox -Filter *.sql | Sort-Object LastWriteTime) {
            $name = $file.BaseName
            $sql = Get-Content $file.FullName -Raw -Encoding UTF8
            Remove-Item $file.FullName
            $csvPath = Join-Path $results "$name.csv"
            $statusPath = Join-Path $results "$name.status.txt"
            try {
                if ($readOnly -and $sql -match $forbidden) { throw "Consulta rechazada: este broker es de solo lectura ($($Matches[1]))." }
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
                $columns = @($table.Columns | ForEach-Object { $_.ColumnName })
                if ($columns.Count -gt 0) {
                    $table.Rows | Select-Object -Property $columns | Export-Csv $csvPath -NoTypeInformation -Encoding UTF8
                }
                if ($columns.Count -gt 0) {
                    $note = if ($table.Rows.Count -ge $MaxRows) { " (limitado a $MaxRows)" } else { '' }
                    $summary = "$($table.Rows.Count) filas$note"
                } else {
                    $summary = "$([Math]::Max(0, $table.ExtendedProperties['RecordsAffected'])) filas afectadas"
                }
                Set-Content $statusPath "OK $summary" -Encoding UTF8
                Write-Host "[$(Get-Date -Format HH:mm:ss)] $name -> $summary"
            } catch {
                Set-Content $statusPath "ERROR $($_.Exception.Message)" -Encoding UTF8
                Write-Host "[$(Get-Date -Format HH:mm:ss)] $name -> ERROR $($_.Exception.Message)"
            }
        }
        Start-Sleep -Milliseconds 500
    }
} finally {
    Remove-Item $ready -ErrorAction SilentlyContinue
    $script:conn.Dispose()
    Write-Host 'Conexion cerrada.'
}
