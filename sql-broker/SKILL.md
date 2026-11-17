---
name: sql-broker
description: Conecta a bases de datos SQL Server / Azure SQL mediante un "broker" local que mantiene la conexión abierta después de que el usuario escriba la contraseña una sola vez en su terminal, para que Claude pueda lanzar consultas sin manejar nunca la contraseña. Para lecturas usa el usuario ai-data-reader (solo lectura); con otros usuarios el broker puede admitir también escrituras. Usa esta skill siempre que el usuario quiera consultar, explorar, hacer un SELECT o modificar datos en una base de datos SQL Server o Azure SQL (por ejemplo miservidor, mibasedatos, *.database.windows.net), pegue una cadena de conexión, pregunte qué hay en una tabla, o mencione "el broker", aunque no lo nombre explícitamente.
---

# SQL Broker: consultas a SQL Server sin que Claude toque la contraseña

## Por qué existe

Claude no introduce contraseñas para autenticarse en servicios reales, ni siquiera cuando el usuario se la da y lo autoriza. El broker resuelve el problema así:

1. El usuario arranca `sql-broker.ps1` en **su** terminal. La contraseña la aporta él: o la escribe, o ya la tiene guardada en el Administrador de credenciales de Windows (ver "Credencial guardada en Windows"). Se guarda solo en la memoria del proceso, como `SecureString`, y nunca en el chat.
2. El broker abre la conexión cifrada y la mantiene abierta. Si Azure la corta por inactividad, se reconecta solo.
3. Claude deja ficheros `.sql` en una carpeta de cola y lee los resultados en CSV. Para eso usa `run-query.ps1` desde su propia shell.

Mientras la pestaña del broker siga abierta, Claude puede hacer todas las consultas que necesite sin molestar al usuario.

## Usuario y modo

El usuario de base de datos decide qué se puede hacer. El broker añade su propio filtro encima:

| Necesidad | Usuario | Cómo se arranca el broker | Modo |
|---|---|---|---|
| Solo leer (lo normal) | `ai-data-reader` | sin `-AllowWrites` | **SOLO LECTURA** |
| Modificar datos o esquema | otro usuario con permisos, el que indique el usuario | con `-AllowWrites` | **LECTURA Y ESCRITURA** |

En **SOLO LECTURA**, el broker aplica una **lista blanca** antes de enviar nada: la consulta debe ser **una sola sentencia** que empiece por `SELECT` o `WITH`, y no puede contener `INTO`, `INSERT`, `UPDATE`, `DELETE`, `MERGE`, `DROP`, `ALTER`, `CREATE`, `TRUNCATE`, `EXEC`, `GRANT`, `REVOKE`, `DENY`, `BACKUP`, `RESTORE`, `OPENROWSET`, `OPENQUERY`, `OPENDATASOURCE`, `BULK`, `WAITFOR`, `DBCC`, `sp_*`/`xp_*` ni `NEXT VALUE FOR` (los comentarios y los textos entre comillas no cuentan). Si necesitas varias sentencias, lanza varias consultas. **Es una barrera adicional, no la protección real:** la protección real son los permisos del usuario de base de datos.

Con `ai-data-reader` el modo es **siempre** SOLO LECTURA, aunque se pase `-AllowWrites`.

Si la tarea solo necesita leer, usa `ai-data-reader` aunque haya otro broker abierto con más permisos. Así un error en una consulta no puede cambiar nada.

Cuando haga falta escribir, pregunta qué usuario usar si no está claro. No des por hecho que existe un usuario con permisos de escritura ni inventes su nombre.

## Scripts

Están en `<SKILL_DIR>\scripts\`:

- `sql-broker.ps1 -Server <srv> -Database <bd> -User <usuario> [-AllowWrites]`: mantiene la conexión abierta. Lo arranca el usuario en el panel Terminal. Busca primero la credencial `sql-broker:<servidor>:<usuario>` en el Administrador de credenciales; si no existe, pide la contraseña por teclado.
- `check-credential.ps1 -Server <srv> -User <usuario>`: dice si esa credencial existe (`EXISTE …` / `NO EXISTE …`). Si no existe, imprime además el comando `cmdkey` ya montado, que hay que ofrecer al usuario (paso 1 bis). No lee ni muestra la contraseña.
- `run-query.ps1 -Server <srv> -Database <bd> [-User <usuario>] -Sql "<consulta>"`: envía una consulta y muestra el estado y la tabla de resultados. Si no se indica `-User`, usa `ai-data-reader`.
- `run-query.ps1 -Server <srv> -Database <bd> [-User <usuario>] -Status`: comprueba si hay un broker conectado para ese usuario, en qué modo está y qué clasificación de datos aplica. `run-query` **borra el CSV y el estado en cuanto los lee**: no quedan resultados en disco.
- `scan-schema.ps1 -Server <srv> -Database <bd> [-User ai-data-reader] [-Contenido]`: propone qué columnas son sensibles sin leer valores (solo nombres, tipos y recuentos). Necesita el broker de lectura conectado. Deja `<bd>.propuesta.json` en `%USERPROFILE%\.sql-broker\classification\<servidor>\`; **la propuesta no se aplica hasta que el usuario la revise** (ver "Clasificación de datos").
- `make-deny-script.ps1 -Server <srv> -Database <bd> [-Usuario ai-data-reader]`: genera el `.sql` con los `DENY SELECT` de una clasificación revisada, para que lo ejecute una persona con permisos. No se conecta a nada.
- `verify-audit.ps1`: comprueba que el registro de actividad no se ha alterado. `selftest.ps1`: pruebas de la lista blanca y del registro, sin base de datos (`powershell.exe -NoProfile -ExecutionPolicy Bypass -File …\selftest.ps1`).

Cada usuario tiene su propio broker y su propia cola, en `%USERPROFILE%\.sql-broker\<servidor>\<bd>\<usuario>\`:
- `inbox\`: consultas pendientes;
- `results\`: un `.csv` y un `.status.txt` por consulta;
- `ready.txt`: existe mientras el broker está conectado y guarda su PID y su modo.

Así puede haber a la vez un broker de lectura y otro de escritura.

**Otros límites:**
- Devuelve como máximo 1000 filas por consulta (`-MaxRows`).
- Cada consulta tiene un tiempo límite de 120 s (`-CommandTimeout`).
- En modo escritura no se reintenta automáticamente una sentencia si la conexión se corta: podría haberse aplicado ya.
- **Cierre por inactividad:** el broker se cierra solo tras 30 min sin consultas (10 min en escritura). Si `run-query` dice `BROKER NO CONECTADO`, vuelve a arrancarlo (paso 3). Se ajusta con `-IdleMinutes`.
- Los resultados que nadie recoja se borran a las 2 h (`-ResultRetentionHours`).
- **Registro de actividad:** cada arranque, consulta (aceptada, rechazada o con error) y cierre queda en `%USERPROFILE%\.sql-broker\_audit\audit-AAAAMM.jsonl`, con fecha, usuario de BD, modo, texto y hash de la consulta, filas y duración, nunca los datos devueltos. Cada línea lleva el hash de la anterior (`verify-audit.ps1`). No borres ni edites esos ficheros.

## Flujo

### 1. Identificar la conexión y el usuario

Necesitas el servidor, la base de datos y el usuario. Si el usuario pega una cadena de conexión, sácalos de `Data Source`, `Initial Catalog` y `User ID`. Si falta `Initial Catalog`, pregunta a qué base de datos conectar: sin ella entraría en `master`.

Elige el usuario según la tabla de arriba.

**Si la cadena incluye una contraseña:** no la uses. Avisa al usuario en una frase de que ha quedado escrita en el chat y de que conviene cambiarla.

Conexiones conocidas:

| Servidor | Base de datos | Usuario | Modo | Notas |
|---|---|---|---|---|
| `miservidor.database.windows.net` | `mibasedatos` | `ai-data-reader` | Solo lectura | Ejemplo: sustituye por tus propios servidor, base de datos y usuario |

### 1 bis. Credencial guardada en Windows: comprobar SIEMPRE antes de arrancar el broker

> **Regla obligatoria.** Antes de arrancar cualquier broker, ejecuta `check-credential.ps1`. Si dice `NO EXISTE`, tu siguiente mensaje **debe incluir el comando `cmdkey` para guardarla**, en su bloque `bash`, aunque el usuario no lo pida y aunque la conexión sea de escritura. Lo opcional es que el usuario la guarde; ofrecérselo **no** lo es. Si no lo has ofrecido, no has terminado este paso.

El broker lee la contraseña de una credencial genérica del Administrador de credenciales de Windows cuyo destino (Dirección de red o Internet) es exactamente `sql-broker:<servidor>:<usuario>`, por ejemplo `sql-broker:miservidor.database.windows.net:ai-data-reader`. Se lee dentro del proceso del broker y no se imprime. Aplica a cualquier base de datos de ese servidor y usuario.

Antes de arrancar el broker, comprueba si existe (no lee la contraseña):

```powershell
& "<SKILL_DIR>\scripts\check-credential.ps1" -Server <servidor> -User <usuario>
```

- **`EXISTE …`:** arranca el broker como en el paso 3. Se conectará solo, sin que el usuario escriba nada, y la salida de su pestaña dirá *"Usando la credencial guardada …"*.
- **`NO EXISTE …`:** el script ya imprime el comando; **escríbelo tú en el chat, sin que el usuario lo pida, ya listo** con el servidor y el usuario de la conexión sustituidos (nunca `<servidor>` ni `<usuario>` sin rellenar), en su propio bloque de código `bash` (así el usuario lo copia o lo ejecuta de un clic). Solo la contraseña queda como marcador `LA_CONTRASEÑA`: no se la pidas nunca al usuario en el chat. Ejemplo para `miservidor.database.windows.net` y `mi-usuario`:

  ```bash
  cmdkey /generic:sql-broker:miservidor.database.windows.net:mi-usuario /user:mi-usuario /pass:'LA_CONTRASEÑA'
  ```

  Añade en una línea que sustituya `LA_CONTRASEÑA` por la real y que borre después esa línea del historial. Después sigue con el broker como en el paso 3 (si no la guarda, el broker la pide por teclado) y no vuelvas a insistir en la credencial en esa conversación. Detalles del comando: (comillas simples para que PowerShell no interprete caracteres como `}` o `$`; una `'` dentro de la contraseña se duplica). Más limpio todavía: Panel de control → Administrador de credenciales → Credenciales de Windows → Agregar una credencial genérica, con ese destino, el usuario y la contraseña. Si no la quiere guardar, el broker la pide por teclado como siempre.
- **Si el usuario quiere ver el valor guardado:** el Administrador de credenciales no tiene botón para mostrarla en las credenciales de Windows. Dale este script, adaptado, para que lo ejecute **él** en su terminal (nunca lo ejecutes tú ni le pidas el resultado):

  ```powershell
  Add-Type -TypeDefinition 'using System;using System.Runtime.InteropServices;public class CM{[DllImport("advapi32.dll",CharSet=CharSet.Unicode,SetLastError=true)]static extern bool CredRead(string t,int ty,int f,out IntPtr p);[StructLayout(LayoutKind.Sequential,CharSet=CharSet.Unicode)]struct C{public int F,T;public string N,Cm;public long L;public int S;public IntPtr B;public int P,A;public IntPtr At;public string TA,U;}public static string Get(string t){IntPtr p;if(!CredRead(t,1,0,out p))return null;C c=(C)Marshal.PtrToStructure(p,typeof(C));return Marshal.PtrToStringUni(c.B,c.S/2);}}'; [CM]::Get('sql-broker:<servidor>:<usuario>')
  ```

  Con `<servidor>` y `<usuario>` sustituidos. Devuelve `null` si no existe.

Solo se usan credenciales con el prefijo `sql-broker:` y el servidor y usuario de la conexión pedida. No se leen ni se enumeran otras credenciales del equipo (por ejemplo las que guarda SSMS).

### 2. Comprobar si ya hay un broker conectado

Ejecuta en tu shell, con la herramienta PowerShell:

```powershell
& "<SKILL_DIR>\scripts\run-query.ps1" -Server miservidor.database.windows.net -Database mibasedatos -User ai-data-reader -Status
```

Si responde `PID … Conectado … Modo …` y el modo es el que necesitas, pasa al paso 4.

### 3. Arrancar el broker en la terminal del usuario

**Antes de lanzarlo, comprueba la credencial (paso 1 bis):** ejecuta `check-credential.ps1` para ese servidor y usuario. Si dice `NO EXISTE`, el script imprime el comando `cmdkey` ya montado: inclúyelo en tu mensaje, en un bloque `bash`, sustituyendo solo la contraseña por `LA_CONTRASEÑA`. Puedes lanzar el broker en ese mismo turno (el usuario teclea la contraseña ahí si no la guarda), pero no sin haberlo ofrecido.

Lánzalo con `run_in_terminal`. La línea tiene que ser literal: sin variables, sin pipes y con la ruta completa.

Solo lectura:

```
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "<SKILL_DIR>\scripts\sql-broker.ps1" -Server miservidor.database.windows.net -Database mibasedatos -User ai-data-reader
```

Con escrituras: el mismo comando, con `-User <usuario-con-permisos> -AllowWrites`. Antes de lanzarlo, avisa al usuario de que ese broker podrá modificar la base de datos.

Se usa `powershell.exe` (Windows PowerShell 5.1) porque trae `System.Data.SqlClient` de serie.

Después, si **no** hay credencial guardada (paso 1 bis), dile al usuario que vaya a esa pestaña (enlázala), escriba la contraseña y pulse Enter. Si la hay, el broker se conecta solo. En ambos casos debería ver *"Conectado a … (modo …)"*. Para la consulta: espera a que `-Status` confirme la conexión antes de seguir.

**No leas esa pestaña con `read_terminal`.** El usuario escribe ahí una contraseña y el clasificador del modo automático bloquea esa lectura. Para saber si ya está conectado, usa `-Status` (paso 2).

### 3 bis. Clasificación de datos: mirarla antes de consultar

Los resultados de las consultas llegan a Claude, es decir, salen del equipo hacia un tercero. Por eso cada base de datos puede tener un fichero de clasificación `%USERPROFILE%\.sql-broker\classification\<servidor>\<bd>.json` con las columnas sensibles. `-Status` dice en la línea `Clasificacion` en qué estado está:

- **`aplicada: N entradas`:** el broker rechaza las consultas que nombran una columna sensible de una tabla clasificada (o cualquier columna de una tabla marcada con `"column": "*"`) y oculta como `[OCULTO]` las columnas del resultado cuyo nombre figura como sensible. **Antes de lanzar una consulta, lee ese fichero.** Si la consulta toca una columna sensible, **no la lances**: díselo al usuario y que lo consulte él en SSMS. No intentes esquivarlo con alias, `LEN()`, `LEFT()` ni expresiones: el enmascarado va por nombre y eso sería saltarse el control. La barrera fiable es el `DENY SELECT` en la base de datos (`make-deny-script.ps1`).
- **`pendiente de revisar`:** hay propuesta pero no se aplica. Trata como sensibles las columnas de la propuesta (`<bd>.propuesta.json`) y avisa al usuario de que falta revisarla.
- **`ninguna`:** ofrece al usuario ejecutar `scan-schema.ps1` (con `-Contenido` si quiere un análisis por contenido: solo devuelve recuentos). Mientras tanto, evita pedir columnas que por su nombre parezcan datos personales (DNI, email, teléfono, IBAN, nombres, direcciones, contraseñas, texto libre) y no muestres más filas de las necesarias.

**Revisión:** el escáner propone y la persona decide. Debe abrir `<bd>.propuesta.json`, borrar lo que no sea sensible, añadir lo que falte, guardarlo como `<bd>.json` y poner `"reviewed": true`, con `reviewedBy` y `reviewedOn`. **No marques tú `reviewed` como true.**

### 4. Lanzar consultas

```powershell
& "<SKILL_DIR>\scripts\run-query.ps1" -Server miservidor.database.windows.net -Database mibasedatos -User ai-data-reader -Sql "SELECT TOP 20 * FROM dbo.MiTabla"
```

Ponle a la herramienta un timeout de unos 180 s, porque `run-query` espera hasta 150 s la respuesta.

- **`OK <n> filas`:** muestra los resultados al usuario en una tabla Markdown y comenta lo que llame la atención (duplicados, valores raros, erratas).
- **`OK <n> filas afectadas`:** resultado de una escritura. Díselo al usuario con el número exacto de filas.
- **`ERROR …`:** el broker sigue vivo. Corrige la consulta y reintenta.
- **`BROKER NO CONECTADO`:** el usuario lo cerró o se cayó. Vuelve al paso 3.

Buenas prácticas:
- Pide solo las columnas y filas que necesites (minimización): evita `SELECT *` sobre tablas con datos personales.
- Usa `TOP` por defecto en tablas grandes.
- Para explorar, empieza por `INFORMATION_SCHEMA.TABLES` y `INFORMATION_SCHEMA.COLUMNS`.
- Cualifica las tablas con su esquema (`dbo.`).

### 4 bis. Escrituras: siempre con confirmación

Una escritura en una base de datos real no se puede deshacer desde aquí. Por eso, aunque el broker la admita:

1. **Antes**, consulta con un `SELECT` (por el broker de lectura) cuántas filas y cuáles se van a ver afectadas.
2. Enseña al usuario la sentencia exacta y ese número, y **espera un "sí" explícito** para esa sentencia concreta. Una aprobación no vale para la siguiente.
3. Ejecútala por el broker de escritura y comprueba que `filas afectadas` coincide con lo previsto. Si no coincide, díselo al usuario enseguida.
4. Para cambios de varias sentencias, propón agruparlas en `BEGIN TRAN … COMMIT` en un solo `.sql`, para que se apliquen todas o ninguna.

### 5. Al terminar

Recuerda al usuario que cierre la pestaña del broker con **Ctrl-C**, sobre todo si es un broker de escritura (se cierra solo por inactividad, pero no hay que esperar). Mientras esté abierta, cualquier proceso de su equipo que deje un `.sql` en la cola puede usar esa conexión: la cola no autentica a quien pide, y es un riesgo residual asumido y documentado.

## Alternativa sin contraseña: Entra ID

Si la cuenta de Entra ID del usuario tiene un usuario en la base de datos (`CREATE USER [correo] FROM EXTERNAL PROVIDER` + `db_datareader`), se puede conectar con un token:
1. Inicia sesión con la skill `azure-cli-session`.
2. Claude obtiene un token con `az account get-access-token --resource https://database.windows.net/`.

Así no hace falta broker. Ofrécelo si el usuario quiere evitar contraseñas del todo.
