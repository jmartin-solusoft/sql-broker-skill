# Genera el script T-SQL con los DENY SELECT de las columnas de una clasificacion REVISADA. Lo debe ejecutar una
# persona con permisos (por ejemplo en SSMS); este script no se conecta a ninguna base de datos.
# Uso: make-deny-script.ps1 -Server <srv> -Database <bd> [-Usuario ai-data-reader]
param(
    [Parameter(Mandatory)][string]$Server,
    [Parameter(Mandatory)][string]$Database,
    [string]$Usuario = 'ai-data-reader'
)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'sql-broker-lib.ps1')
$cls = Get-Classification $Server $Database
if (-not $cls) { throw "No hay clasificacion para $Server/$Database." }
if (-not $cls.reviewed) { throw 'La clasificacion no esta revisada (reviewed = false). Revisela antes de generar los DENY.' }
function Qid([string]$n) { '[' + ($n -replace '\]', ']]') + ']' }
$u = Qid $Usuario
$deny = New-Object System.Collections.ArrayList
$revoke = New-Object System.Collections.ArrayList
foreach ($g in (@($cls.sensitive) | Group-Object { "$($_.schema).$($_.table)" })) {
    $s = Qid $g.Group[0].schema; $t = Qid $g.Group[0].table
    if (@($g.Group | Where-Object { [string]$_.column -eq '*' }).Count -gt 0) {
        [void]$deny.Add("DENY SELECT ON $s.$t TO $u;")
        [void]$revoke.Add("-- REVOKE SELECT ON $s.$t FROM $u;")
    } else {
        $c = (@($g.Group | ForEach-Object { Qid ([string]$_.column) }) -join ', ')
        [void]$deny.Add("DENY SELECT ON $s.$t ($c) TO $u;")
        [void]$revoke.Add("-- REVOKE SELECT ON $s.$t ($c) FROM $u;")
    }
}
$dirOut = Split-Path (Get-ClassificationPath $Server $Database)
$out = Join-Path $dirOut "deny-$Database-$Usuario.sql"
$txt = @(
    "-- DENY SELECT sobre columnas sensibles para $Usuario en $Database ($Server)",
    "-- Generado el $((Get-Date).ToString('s')) desde la clasificacion revisada. Ejecutar con un usuario con permisos, en $Database.",
    "-- DENY prevalece sobre cualquier GRANT o pertenencia a db_datareader. Probar primero en preproduccion.",
    ''
) + $deny + @('', '-- Para revertir:') + $revoke
[IO.File]::WriteAllText($out, ($txt -join "`r`n"), (New-Object System.Text.UTF8Encoding($false)))
"Generado: $out ($($deny.Count) sentencias DENY)"
