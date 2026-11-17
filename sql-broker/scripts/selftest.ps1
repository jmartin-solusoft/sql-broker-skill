# Pruebas sin base de datos de la lista blanca, la clasificacion y el registro de actividad.
# Uso: powershell.exe -NoProfile -ExecutionPolicy Bypass -File selftest.ps1
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'sql-broker-lib.ps1')
$fallos = 0
function Check([string]$nombre, $cond) { if ($cond) { "  ok   $nombre" } else { "  FALLA $nombre"; $script:fallos++ } }

"Lista blanca de solo lectura - deben ACEPTARSE"
$ok = @(
    'SELECT TOP 20 * FROM dbo.MiTabla',
    'select 1;',
    "SELECT 'INSERT UPDATE DELETE' AS txt",
    'SELECT [update], [into] FROM [dbo].[t]',
    '/* nota */ SELECT 1 -- DROP TABLE x',
    'WITH a AS (SELECT 1 AS n) SELECT n FROM a',
    "SELECT * FROM INFORMATION_SCHEMA.COLUMNS WHERE TABLE_NAME = 'xp_cmdshell'",
    'SELECT DELETE_FLAG, Created, Updated FROM dbo.t'
)
foreach ($q in $ok) { Check $q ($null -eq (Test-ReadOnlySql $q)) }

"Lista blanca de solo lectura - deben RECHAZARSE"
$mal = @(
    'SELECT * INTO nueva FROM dbo.t',
    'sp_who',
    'sp_executesql N''select 1''',
    'EXEC sp_who',
    'SELECT 1; DROP TABLE x',
    'SELECT 1; SELECT 2',
    'UPDATE dbo.t SET a = 1',
    'WITH a AS (SELECT 1 AS n) DELETE FROM dbo.t',
    "SELECT * FROM OPENROWSET('SQLNCLI','x','select 1')",
    'SELECT * FROM OPENQUERY(srv, ''select 1'')',
    'DECLARE @a int = 1 SELECT @a',
    'SELECT NEXT VALUE FOR dbo.seq',
    'SELECT xp_cmdshell',
    '',
    'SELECT /* sin cerrar',
    "SELECT 'sin cerrar"
)
foreach ($q in $mal) { Check ("rechaza: " + ($q -replace '\s+', ' ')) ($null -ne (Test-ReadOnlySql $q)) }

"Clasificacion de columnas"
$cls = '{"reviewed":true,"sensitive":[{"schema":"dbo","table":"CLIENTES","column":"dni","category":"identificador"},{"schema":"dbo","table":"NOTAS","column":"*","category":"texto libre"}]}' | ConvertFrom-Json
Check 'rechaza LEN(dni) de CLIENTES' ($null -ne (Test-SensitiveReference 'SELECT LEN(dni) FROM dbo.CLIENTES' $cls))
Check 'rechaza dni entre corchetes' ($null -ne (Test-SensitiveReference 'SELECT [DNI] FROM [dbo].[clientes]' $cls))
Check 'rechaza tabla entera NOTAS' ($null -ne (Test-SensitiveReference 'SELECT TOP 5 * FROM dbo.NOTAS' $cls))
Check 'acepta dni de otra tabla' ($null -eq (Test-SensitiveReference 'SELECT dni FROM dbo.PROVEEDORES' $cls))
Check 'acepta otra columna de CLIENTES' ($null -eq (Test-SensitiveReference 'SELECT id, ciudad FROM dbo.CLIENTES' $cls))
Check 'acepta metadatos' ($null -eq (Test-SensitiveReference "SELECT COLUMN_NAME FROM INFORMATION_SCHEMA.COLUMNS WHERE TABLE_NAME = 'CLIENTES'" $cls))
$pend = '{"reviewed":false,"sensitive":[{"schema":"dbo","table":"CLIENTES","column":"dni"}]}' | ConvertFrom-Json
Check 'sin revisar no se aplica' ($null -eq (Test-SensitiveReference 'SELECT dni FROM dbo.CLIENTES' $pend))
Check 'nombres a ocultar en el resultado' ((Get-SensitiveColumnNames $cls) -contains 'dni')

"Registro de actividad encadenado"
$tmp = Join-Path ([IO.Path]::GetTempPath()) ('audit-selftest-' + [guid]::NewGuid().ToString('N'))
$script:BrokerRoot = $tmp
Write-AuditEntry ([ordered]@{ event = 'start'; sql = 'SELECT 1 -- "comillas" y barra \ final' })
Write-AuditEntry ([ordered]@{ event = 'query'; rows = 3; outcome = 'ok' })
Write-AuditEntry ([ordered]@{ event = 'stop' })
$f = Get-ChildItem (Join-Path $tmp '_audit') -Filter 'audit-*.jsonl' | Select-Object -First 1
$lineas = @(Get-Content $f.FullName -Encoding UTF8)
Check 'tres lineas' ($lineas.Count -eq 3)
$cadena = $true; $prev = '0' * 64
foreach ($l in $lineas) {
    if ($l -notmatch '^(.*),"h":"([0-9a-f]{64})"\}$') { $cadena = $false; continue }
    $cuerpo = $Matches[1] + '}'; $hash = $Matches[2]
    if ((Get-Sha256Hex $cuerpo) -ne $hash) { $cadena = $false }
    if (-not $l.Contains('"prev":"' + $prev + '"')) { $cadena = $false }
    $prev = $hash
}
Check 'hashes y enlaces correctos' $cadena
Remove-Item $tmp -Recurse -Force

""
if ($fallos) { "$fallos prueba(s) fallida(s)"; exit 1 } else { 'Todas las pruebas correctas'; exit 0 }
