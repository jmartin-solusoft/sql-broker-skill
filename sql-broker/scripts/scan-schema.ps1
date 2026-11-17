# Propone que columnas de una base de datos son sensibles SIN leer ningun valor: usa el broker de lectura y solo
# recibe nombres, tipos y recuentos. El resultado es una PROPUESTA (<bd>.propuesta.json) que debe revisar una persona.
#   1) por nombre de columna (dni, email, iban, password, ...) y por tipo (texto libre);
#   2) con las clasificaciones que ya tenga Azure (sys.sensitivity_classifications), si el usuario puede verlas;
#   3) con -Contenido: cuenta cuantas filas de una muestra tienen forma de email, DNI/NIE, telefono o IBAN.
# Uso: scan-schema.ps1 -Server <srv> -Database <bd> [-User ai-data-reader] [-Contenido] [-Muestra 500] [-MaxTablas 0]
# Requiere un broker ya conectado para ese servidor, base de datos y usuario (ver run-query.ps1 -Status).
param(
    [Parameter(Mandatory)][string]$Server,
    [Parameter(Mandatory)][string]$Database,
    [string]$User = 'ai-data-reader',
    [switch]$Contenido,
    [int]$Muestra = 500,
    [int]$MaxTablas = 0
)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'sql-broker-lib.ps1')
$rq = Join-Path $PSScriptRoot 'run-query.ps1'
function Q([string]$sql) { @(& $rq -Server $Server -Database $Database -User $User -Sql $sql -AsObjects) }
function Qid([string]$n) { '[' + ($n -replace '\]', ']]') + ']' }

# --- 1. Columnas (paginado: el broker devuelve como maximo 1000 filas por consulta) ----------------------------
Write-Host "Leyendo columnas de $Database en $Server ..."
$cols = New-Object System.Collections.ArrayList
$off = 0
while ($true) {
    $page = Q ("SELECT c.TABLE_SCHEMA, c.TABLE_NAME, c.COLUMN_NAME, c.DATA_TYPE, c.CHARACTER_MAXIMUM_LENGTH, t.TABLE_TYPE " +
        "FROM INFORMATION_SCHEMA.COLUMNS c JOIN INFORMATION_SCHEMA.TABLES t ON t.TABLE_SCHEMA = c.TABLE_SCHEMA AND t.TABLE_NAME = c.TABLE_NAME " +
        "ORDER BY c.TABLE_SCHEMA, c.TABLE_NAME, c.ORDINAL_POSITION OFFSET $off ROWS FETCH NEXT 1000 ROWS ONLY")
    foreach ($r in $page) { [void]$cols.Add($r) }
    if ($page.Count -lt 1000) { break }
    $off += 1000
}
$tablas = @($cols | Group-Object TABLE_SCHEMA, TABLE_NAME).Count
Write-Host "  $($cols.Count) columnas en $tablas tablas/vistas."

# --- 2. Clasificaciones de Azure, si estan disponibles -------------------------------------------------------
$azure = @{}
try {
    $az = Q ("SELECT SCHEMA_NAME(o.schema_id) AS s, o.name AS t, c.name AS c, sc.label, sc.information_type FROM sys.sensitivity_classifications sc " +
        "JOIN sys.objects o ON o.object_id = sc.major_id JOIN sys.columns c ON c.object_id = sc.major_id AND c.column_id = sc.minor_id")
    foreach ($r in $az) { $azure["$($r.s).$($r.t).$($r.c)"] = (($r.label, $r.information_type) | Where-Object { $_ }) -join ' / ' }
    Write-Host "  Clasificaciones de Azure encontradas: $($azure.Count)."
} catch { Write-Host "  Sin acceso a sys.sensitivity_classifications (se sigue sin ellas)." }

# --- 3. Reglas por nombre y por tipo -------------------------------------------------------------------------
$reglas = @(
    @('identificador personal o fiscal', '(^|_)(dni|nif|nie|cif|pasaporte|passport|ssn|nuss|naf|documento|identificacion)($|_)'),
    @('secreto',                         '(password|passwd|pwd|contrasena|secret|token|apikey|api_key|^clave$|(^|_)hash($|_)|(^|_)salt($|_)|credential|private_?key|connection_?string|cadena_?conexion)'),
    @('financiero',                      '(^|_)(iban|ccc|swift|bic|tarjeta|card|pan|cvv|cvc|salario|sueldo|nomina|salary|retribucion)($|_)|cuenta_?banc'),
    @('contacto',                        '(mail|correo|(^|_)(tel|tlf|telf|telefono|movil|phone|mobile|fax)($|_))'),
    @('nombre de persona',               '(nombre|apellido|surname|firstname|lastname|first_?name|last_?name|full_?name|razon_?social)'),
    @('direccion',                       '(direccion|domicilio|address|calle|street|codigo_?postal|zip|(^|_)cp($|_))'),
    @('datos personales',                '(nacimiento|birth|fecha_?nac|(^|_)edad($|_)|(^|_)sexo($|_)|(^|_)genero($|_)|gender)'),
    @('localizacion',                    '(latitud|longitud|latitude|longitude|(^|_)lat($|_)|(^|_)lon(g)?($|_)|gps|geom|ubicacion|location|(^|_)ip($|_)|ip_?address|matricula|plate)'),
    @('categoria especial',              '(salud|health|diagnostico|enfermedad|discapacidad|religion|sindicato|afiliacion)'),
    @('texto libre (por nombre)',        '(observaciones|(^|_)notas?($|_)|comentarios?|comments?|(^|_)notes?($|_)|remarks|memo|detalle)')
)
$existente = $null
$pathJson = Get-ClassificationPath $Server $Database
if (Test-Path $pathJson) { $existente = Get-Classification $Server $Database }
$yaClasificadas = @{}
if ($existente) { foreach ($e in @($existente.sensitive)) { $yaClasificadas["$($e.schema).$($e.table).$($e.column)"] = $true } }

$prop = @{}   # clave schema.tabla.columna -> entrada
foreach ($c in $cols) {
    $k = "$($c.TABLE_SCHEMA).$($c.TABLE_NAME).$($c.COLUMN_NAME)"
    $n = $c.COLUMN_NAME.ToLowerInvariant()
    $cat = $null; $src = 'nombre'
    if ($azure.ContainsKey($k)) { $cat = "Azure: $($azure[$k])"; $src = 'azure' }
    else {
        foreach ($r in $reglas) { if ($n -match $r[1]) { $cat = $r[0]; break } }
        if (-not $cat) {
            $len = 0; [void][int]::TryParse([string]$c.CHARACTER_MAXIMUM_LENGTH, [ref]$len)
            if ($c.DATA_TYPE -in @('text', 'ntext') -or ($c.DATA_TYPE -in @('varchar', 'nvarchar') -and ($len -lt 0 -or $len -ge 500))) { $cat = 'texto libre (por tipo)'; $src = 'tipo' }
        }
    }
    if ($cat) {
        $prop[$k] = [ordered]@{ schema = $c.TABLE_SCHEMA; table = $c.TABLE_NAME; column = $c.COLUMN_NAME; dataType = $c.DATA_TYPE; category = $cat; source = $src; hits = $null }
    }
}

# --- 4. Por contenido (opcional): solo recuentos, nunca valores -----------------------------------------------
if ($Contenido) {
    $textTypes = @('char', 'varchar', 'nchar', 'nvarchar', 'text', 'ntext')
    $porTabla = $cols | Where-Object { $_.TABLE_TYPE -eq 'BASE TABLE' -and $_.DATA_TYPE -in $textTypes } | Group-Object TABLE_SCHEMA, TABLE_NAME
    if ($MaxTablas -gt 0) { $porTabla = @($porTabla | Select-Object -First $MaxTablas) }
    Write-Host "Escaneo por contenido (muestra de $Muestra filas por tabla) en $(@($porTabla).Count) tablas ..."
    $hecho = 0
    foreach ($g in $porTabla) {
        $hecho++
        if ($hecho % 25 -eq 0) { Write-Host "  $hecho / $(@($porTabla).Count)" }
        $s = $g.Group[0].TABLE_SCHEMA; $t = $g.Group[0].TABLE_NAME
        $cand = @($g.Group | Where-Object { -not $prop.ContainsKey("$s.$t.$($_.COLUMN_NAME)") -and -not $yaClasificadas.ContainsKey("$s.$t.$($_.COLUMN_NAME)") })
        for ($i = 0; $i -lt $cand.Count; $i += 30) {
            $lote = @($cand[$i..([Math]::Min($i + 29, $cand.Count - 1))])
            $exprs = New-Object System.Collections.ArrayList
            for ($j = 0; $j -lt $lote.Count; $j++) {
                $x = "CONVERT(nvarchar(4000), $(Qid $lote[$j].COLUMN_NAME))"
                [void]$exprs.Add("SUM(CASE WHEN $x LIKE '%_@_%._%' AND $x NOT LIKE '% %' THEN 1 ELSE 0 END) AS e$j")
                [void]$exprs.Add("SUM(CASE WHEN $x LIKE '[0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][A-Za-z]' OR $x LIKE '[XYZxyz][0-9][0-9][0-9][0-9][0-9][0-9][0-9][A-Za-z]' THEN 1 ELSE 0 END) AS d$j")
                [void]$exprs.Add("SUM(CASE WHEN $x LIKE '[6-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]' OR $x LIKE '+34[6-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]' THEN 1 ELSE 0 END) AS p$j")
                [void]$exprs.Add("SUM(CASE WHEN $x LIKE '[A-Za-z][A-Za-z][0-9][0-9]%' AND LEN(REPLACE($x, ' ', '')) BETWEEN 15 AND 34 AND $x NOT LIKE '%[^A-Za-z0-9 ]%' THEN 1 ELSE 0 END) AS i$j")
                [void]$exprs.Add("COUNT($(Qid $lote[$j].COLUMN_NAME)) AS n$j")
            }
            try {
                $r = (Q ("SELECT $($exprs -join ', ') FROM (SELECT TOP ($Muestra) * FROM $(Qid $s).$(Qid $t)) AS m"))[0]
            } catch { Write-Host "  (omitida $s.$t : $($_.Exception.Message))"; break }
            for ($j = 0; $j -lt $lote.Count; $j++) {
                $n = [int]$r."n$j"
                if ($n -eq 0) { continue }
                foreach ($f in @(@('e', 'contenido: email'), @('d', 'contenido: DNI/NIE'), @('p', 'contenido: telefono'), @('i', 'contenido: IBAN'))) {
                    $h = [int]$r."$($f[0])$j"
                    if ($h -ge 3 -or ($h -ge 1 -and $h / $n -ge 0.2)) {
                        $k = "$s.$t.$($lote[$j].COLUMN_NAME)"
                        $prop[$k] = [ordered]@{ schema = $s; table = $t; column = $lote[$j].COLUMN_NAME; dataType = $lote[$j].DATA_TYPE; category = $f[1]; source = 'contenido'; hits = "$h de $n" }
                        break
                    }
                }
            }
        }
    }
}

# --- 5. Salida: propuesta + resumen (sin valores) -------------------------------------------------------------
$lista = @($prop.Values | Sort-Object { $_.schema }, { $_.table }, { $_.column })
$doc = [ordered]@{
    server = $Server; database = $Database; generated = (Get-Date).ToString('s'); scanner = 'scan-schema 1'
    reviewed = $false; reviewedBy = ''; reviewedOn = ''
    notes = 'PROPUESTA automatica. Borre las entradas que no sean sensibles, anada las que falten (column "*" = tabla entera) y ponga reviewed en true. Hasta entonces el broker NO la aplica.'
    sensitive = $lista
}
$dir = Split-Path (Get-ClassificationPath $Server $Database)
New-Item -ItemType Directory -Force $dir | Out-Null
$out = Join-Path $dir "$Database.propuesta.json"
[IO.File]::WriteAllText($out, ($doc | ConvertTo-Json -Depth 6), (New-Object System.Text.UTF8Encoding($false)))

""
"Propuesta: $out"
"Columnas propuestas: $($lista.Count) de $($cols.Count)"
$lista | Group-Object { $_.category } | Sort-Object Count -Descending | ForEach-Object { "{0,6}  {1}" -f $_.Count, $_.Name }
""
"Tablas con mas columnas propuestas:"
$lista | Group-Object { "$($_.schema).$($_.table)" } | Sort-Object Count -Descending | Select-Object -First 15 | ForEach-Object { "{0,6}  {1}" -f $_.Count, $_.Name }
""
if ($existente) { "Ya existe $pathJson (reviewed = $($existente.reviewed)); no se ha tocado." }
else { "Siguiente paso: revise la propuesta, guardela como $pathJson y ponga reviewed en true." }
