# Comprueba la cadena de hashes del registro de actividad del broker (%USERPROFILE%\.sql-broker\_audit).
# Cada linea lleva "prev" (hash de la anterior) y "h" (hash de su propio contenido): si alguien edita o borra una
# linea, la cadena se rompe. Uso: verify-audit.ps1 [-Mes yyyyMM] [-Ultimas 20]
param([string]$Mes, [int]$Ultimas = 0)
$dir = Join-Path $env:USERPROFILE '.sql-broker\_audit'
$files = if ($Mes) { Get-ChildItem $dir -Filter "audit-$Mes.jsonl" } else { Get-ChildItem $dir -Filter 'audit-*.jsonl' | Sort-Object Name }
if (-not $files) { 'No hay registros de actividad.'; exit 1 }
function Get-Sha256Hex([string]$t) { $s = [Security.Cryptography.SHA256]::Create(); try { ([BitConverter]::ToString($s.ComputeHash([Text.Encoding]::UTF8.GetBytes($t))) -replace '-', '').ToLowerInvariant() } finally { $s.Dispose() } }
$bad = 0; $total = 0; $prev = $null
foreach ($f in $files) {
    $n = 0
    foreach ($line in Get-Content $f.FullName -Encoding UTF8) {
        if (-not $line) { continue }
        $n++; $total++
        if ($line -notmatch '^(.*),"h":"([0-9a-f]{64})"\}$') { "$($f.Name) linea ${n}: formato no valido"; $bad++; continue }
        $body = $Matches[1] + '}'; $h = $Matches[2]
        if ((Get-Sha256Hex $body) -ne $h) { "$($f.Name) linea ${n}: contenido alterado"; $bad++ }
        $p = if ($line -match '"prev":"([0-9a-f]{64})"') { $Matches[1] } else { '' }
        if ($null -ne $prev -and $p -ne $prev -and -not ($p -eq ('0' * 64) -and $n -eq 1)) { "$($f.Name) linea ${n}: cadena rota (falta o sobra alguna linea)"; $bad++ }
        $prev = $h
    }
}
"Lineas revisadas: $total | problemas: $bad"
if ($Ultimas -gt 0) { $files | Select-Object -Last 1 | ForEach-Object { Get-Content $_.FullName -Tail $Ultimas -Encoding UTF8 } }
exit ([int]($bad -gt 0))
