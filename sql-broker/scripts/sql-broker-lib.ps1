# Funciones compartidas por sql-broker.ps1, scan-schema.ps1 y selftest.ps1. Solo ASCII (Windows PowerShell 5.1).
#   Remove-SqlNoise        quita comentarios y literales para analizar la consulta sin falsos positivos
#   Test-ReadOnlySql       lista blanca de solo lectura (una sola sentencia SELECT/WITH, sin INTO ni OPEN*)
#   Get-Classification    carga la clasificacion de columnas sensibles de un servidor/BD
#   Test-SensitiveReference  rechaza consultas que nombran una columna sensible de una tabla clasificada
#   Write-AuditEntry       registro de actividad encadenado con hash (ver verify-audit.ps1)

$script:BrokerRoot = Join-Path $env:USERPROFILE '.sql-broker'

function Remove-SqlNoise {
    # Sustituye comentarios por un espacio y los literales 'texto' por 'x'. Los identificadores entre [] o "" se
    # sustituyen por [x] / "x", salvo con -KeepIdentifiers (se devuelve su contenido, para buscar nombres de tablas).
    # Lanza una excepcion si algo queda sin cerrar: ante la duda, se rechaza.
    param([string]$Sql, [switch]$KeepIdentifiers)
    $sb = New-Object System.Text.StringBuilder
    $n = $Sql.Length
    $i = 0
    while ($i -lt $n) {
        $c = $Sql[$i]
        $d = [char]0
        if ($i + 1 -lt $n) { $d = $Sql[$i + 1] }
        if ($c -eq [char]'-' -and $d -eq [char]'-') {
            while ($i -lt $n -and $Sql[$i] -ne [char]10) { $i++ }
            [void]$sb.Append(' ')
        }
        elseif ($c -eq [char]'/' -and $d -eq [char]'*') {
            $depth = 1
            $i += 2
            while ($i -lt $n -and $depth -gt 0) {
                if ($Sql[$i] -eq [char]'/' -and ($i + 1) -lt $n -and $Sql[$i + 1] -eq [char]'*') { $depth++; $i += 2 }
                elseif ($Sql[$i] -eq [char]'*' -and ($i + 1) -lt $n -and $Sql[$i + 1] -eq [char]'/') { $depth--; $i += 2 }
                else { $i++ }
            }
            if ($depth -gt 0) { throw 'comentario /* sin cerrar' }
            [void]$sb.Append(' ')
        }
        elseif ($c -eq [char]"'" -or $c -eq [char]'"' -or $c -eq [char]'[') {
            $close = $c
            if ($c -eq [char]'[') { $close = [char]']' }
            $i++
            $start = $i
            $closed = $false
            while ($i -lt $n) {
                if ($Sql[$i] -eq $close) {
                    if (($i + 1) -lt $n -and $Sql[$i + 1] -eq $close) { $i += 2; continue }
                    $closed = $true
                    break
                }
                $i++
            }
            if (-not $closed) { throw "texto o identificador sin cerrar ($c)" }
            $inner = $Sql.Substring($start, $i - $start)
            $i++
            if ($c -eq [char]"'") { [void]$sb.Append("'x'") }
            elseif ($KeepIdentifiers) { [void]$sb.Append(' ').Append($inner).Append(' ') }
            else { [void]$sb.Append($c).Append('x').Append($close) }
        }
        else {
            [void]$sb.Append($c)
            $i++
        }
    }
    $sb.ToString()
}

function Test-ReadOnlySql {
    # Devuelve $null si la consulta es aceptable en modo solo lectura, o el motivo del rechazo.
    # Es una barrera adicional: la proteccion fiable son los permisos del usuario de base de datos.
    param([string]$Sql)
    try { $s = Remove-SqlNoise $Sql } catch { return "no se puede analizar la consulta ($($_.Exception.Message))" }
    $s = ($s.Trim()) -replace '[;\s]+$', ''
    if ($s -eq '') { return 'consulta vacia' }
    if ($s.Contains(';')) { return 'solo se admite una sentencia (hay un ; intermedio)' }
    if ($s -notmatch '^(SELECT|WITH)\b') { return 'solo se admiten consultas que empiecen por SELECT o WITH' }
    $bad = '\b(INSERT|UPDATE|DELETE|MERGE|DROP|ALTER|CREATE|TRUNCATE|EXEC|EXECUTE|GRANT|REVOKE|DENY|BACKUP|RESTORE|INTO|OPENROWSET|OPENQUERY|OPENDATASOURCE|BULK|WAITFOR|DBCC|KILL|SHUTDOWN|RECONFIGURE)\b'
    if ($s -match $bad) { return "palabra no permitida ($($Matches[1]))" }
    if ($s -match '\b(xp|sp)_\w+') { return "procedimiento de sistema no permitido ($($Matches[0]))" }
    if ($s -match '\bNEXT\s+VALUE\s+FOR\b') { return 'NEXT VALUE FOR modifica una secuencia' }
    $null
}

function Get-ClassificationPath {
    param([string]$Server, [string]$Database)
    Join-Path $script:BrokerRoot "classification\$Server\$Database.json"
}

function Get-Classification {
    # $null si no hay fichero. Lanza excepcion si existe pero no se puede leer (el broker falla cerrado).
    param([string]$Server, [string]$Database)
    $p = Get-ClassificationPath $Server $Database
    if (-not (Test-Path $p)) { return $null }
    Get-Content $p -Raw -Encoding UTF8 | ConvertFrom-Json
}

function Test-SensitiveReference {
    # Solo actua si la clasificacion esta revisada (reviewed = true). Rechaza si la consulta nombra una tabla
    # clasificada y una de sus columnas sensibles (o cualquier columna, si la entrada es column = "*").
    param([string]$Sql, $Classification)
    if (-not $Classification -or -not $Classification.reviewed) { return $null }
    try { $s = Remove-SqlNoise $Sql -KeepIdentifiers } catch { return "no se puede analizar la consulta ($($_.Exception.Message))" }
    foreach ($e in @($Classification.sensitive)) {
        $t = [regex]::Escape([string]$e.table)
        if ($s -notmatch "(?<![\w@#])$t(?![\w])") { continue }
        if ([string]$e.column -eq '*') { return "la tabla $($e.schema).$($e.table) esta clasificada como sensible entera ($($e.category))" }
        $c = [regex]::Escape([string]$e.column)
        if ($s -match "(?<![\w@#])$c(?![\w])") { return "la columna $($e.schema).$($e.table).$($e.column) esta clasificada como sensible ($($e.category))" }
    }
    $null
}

function Get-SensitiveColumnNames {
    param($Classification)
    if (-not $Classification -or -not $Classification.reviewed) { return @() }
    @($Classification.sensitive | Where-Object { [string]$_.column -ne '*' } | ForEach-Object { ([string]$_.column).ToLowerInvariant() } | Select-Object -Unique)
}

# --- Registro de actividad: JSON lineal por evento, cada linea lleva el hash de la anterior ----------------
$script:AuditFile = $null
$script:AuditPrev = ''

function Get-Sha256Hex([string]$text) {
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try { ([BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($text))) -replace '-', '').ToLowerInvariant() }
    finally { $sha.Dispose() }
}

function Write-AuditEntry {
    param([System.Collections.Specialized.OrderedDictionary]$Entry)
    $dir = Join-Path $script:BrokerRoot '_audit'
    New-Item -ItemType Directory -Force $dir | Out-Null
    $file = Join-Path $dir ("audit-{0}.jsonl" -f (Get-Date -Format 'yyyyMM'))
    if ($script:AuditFile -ne $file) {
        $script:AuditFile = $file
        $script:AuditPrev = ('0' * 64)
        if (Test-Path $file) {
            $last = Get-Content $file -Tail 1 -Encoding UTF8
            if ($last -match '"h":"([0-9a-f]{64})"\}$') { $script:AuditPrev = $Matches[1] }
        }
    }
    $e = [ordered]@{ ts = (Get-Date).ToString('s'); host = $env:COMPUTERNAME; winuser = $env:USERNAME }
    foreach ($k in $Entry.Keys) { $e[$k] = $Entry[$k] }
    $e['prev'] = $script:AuditPrev
    $body = $e | ConvertTo-Json -Compress
    $h = Get-Sha256Hex $body
    $line = $body.Substring(0, $body.Length - 1) + ',"h":"' + $h + '"}'
    Add-Content -Path $file -Value $line -Encoding UTF8
    $script:AuditPrev = $h
}
