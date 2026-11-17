# Deja una consulta en la cola de un sql-broker.ps1 en marcha, espera su resultado y lo muestra.
# Uso: run-query.ps1 -Server <servidor> -Database <bd> [-User <usuario>] -Sql "SELECT ..."
#      run-query.ps1 -Server <servidor> -Database <bd> [-User <usuario>] -Status   (solo comprueba si el broker esta conectado y su modo)
#      run-query.ps1 ... -Sql "SELECT ..." -AsObjects   (devuelve las filas como objetos y lanza error si falla; para scripts como scan-schema.ps1)
# -User por defecto es ai-data-reader: cada usuario tiene su propio broker y su propia cola.
# El CSV y el estado de la consulta se borran en cuanto se leen: no quedan resultados en disco.
param(
    [Parameter(Mandatory)][string]$Server,
    [Parameter(Mandatory)][string]$Database,
    [string]$User = 'ai-data-reader',
    [string]$Sql,
    [switch]$Status,
    [switch]$AsObjects,
    [int]$TimeoutSeconds = 150,
    [string]$QueueDir
)

$ErrorActionPreference = 'Stop'
if (-not $QueueDir) { $QueueDir = Join-Path $env:USERPROFILE ".sql-broker\$Server\$Database\$User" }
$inbox = Join-Path $QueueDir 'inbox'
$ready = Join-Path $QueueDir 'ready.txt'

# El broker escribe ready.txt al conectar y lo borra al salir; si se cerro la pestana de golpe, el PID ya no existe
$brokerPid = if (Test-Path $ready) { (Get-Content $ready -Encoding UTF8 | Select-Object -First 1) -replace '^PID\s+', '' } else { $null }
$running = $brokerPid -and (Get-Process -Id $brokerPid -ErrorAction SilentlyContinue)
if (-not $running) {
    $msg = "BROKER NO CONECTADO para $Database en $Server como $User. Hay que arrancar sql-broker.ps1 y que el usuario escriba la contrasena."
    if ($AsObjects) { throw $msg }
    Write-Output $msg
    exit 2
}
if ($Status) { Get-Content $ready -Encoding UTF8; exit 0 }
if (-not $Sql) { throw 'Falta -Sql (o usa -Status).' }

$name = Get-Date -Format 'yyyyMMdd-HHmmss-fff'
$tmp = Join-Path $inbox "$name.tmp"
Set-Content $tmp $Sql -Encoding UTF8
Rename-Item $tmp "$name.sql"   # el broker solo ve el fichero cuando ya esta completo

$statusFile = Join-Path $QueueDir "results\$name.status.txt"
$csv = Join-Path $QueueDir "results\$name.csv"
$deadline = (Get-Date).AddSeconds($TimeoutSeconds)
while (-not (Test-Path $statusFile)) {
    if ((Get-Date) -gt $deadline) { throw "Sin respuesta del broker en $TimeoutSeconds s." }
    Start-Sleep -Milliseconds 500
}

try {
    $statusLines = @(Get-Content $statusFile -Encoding UTF8)
    $rows = if (Test-Path $csv) { @(Import-Csv $csv) } else { @() }
} finally {
    Remove-Item $statusFile, $csv -Force -ErrorAction SilentlyContinue
}

if ($AsObjects) {
    if ($statusLines[0] -notmatch '^OK') { throw ($statusLines -join ' ') }
    $rows
} else {
    $statusLines
    if ($rows.Count -gt 0) { $rows | Format-Table -AutoSize | Out-String -Width 400 }
}
