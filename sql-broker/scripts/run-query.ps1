# Deja una consulta en la cola de un sql-broker.ps1 en marcha, espera su resultado y lo muestra.
# Uso: run-query.ps1 -Server <servidor> -Database <bd> [-User <usuario>] -Sql "SELECT ..."
#      run-query.ps1 -Server <servidor> -Database <bd> [-User <usuario>] -Status   (solo comprueba si el broker esta conectado y su modo)
# -User por defecto es ai-data-reader: cada usuario tiene su propio broker y su propia cola.
param(
    [Parameter(Mandatory)][string]$Server,
    [Parameter(Mandatory)][string]$Database,
    [string]$User = 'ai-data-reader',
    [string]$Sql,
    [switch]$Status,
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
    Write-Output "BROKER NO CONECTADO para $Database en $Server como $User. Hay que arrancar sql-broker.ps1 y que el usuario escriba la contrasena."
    exit 2
}
if ($Status) { Get-Content $ready -Encoding UTF8; exit 0 }
if (-not $Sql) { throw 'Falta -Sql (o usa -Status).' }

$name = Get-Date -Format 'yyyyMMdd-HHmmss-fff'
$tmp = Join-Path $inbox "$name.tmp"
Set-Content $tmp $Sql -Encoding UTF8
Rename-Item $tmp "$name.sql"   # el broker solo ve el fichero cuando ya esta completo

$statusFile = Join-Path $QueueDir "results\$name.status.txt"
$deadline = (Get-Date).AddSeconds($TimeoutSeconds)
while (-not (Test-Path $statusFile)) {
    if ((Get-Date) -gt $deadline) { throw "Sin respuesta del broker en $TimeoutSeconds s." }
    Start-Sleep -Milliseconds 500
}

Get-Content $statusFile -Encoding UTF8
$csv = Join-Path $QueueDir "results\$name.csv"
if (Test-Path $csv) { Import-Csv $csv | Format-Table -AutoSize | Out-String -Width 400 }
