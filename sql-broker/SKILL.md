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

En **SOLO LECTURA**, el broker rechaza `INSERT`, `UPDATE`, `DELETE`, `MERGE`, `DROP`, `ALTER`, `CREATE`, `TRUNCATE`, `EXEC`, `GRANT`, `REVOKE`, `DENY`, `BACKUP` y `RESTORE` antes de enviarlos.

Con `ai-data-reader` el modo es **siempre** SOLO LECTURA, aunque se pase `-AllowWrites`.

Si la tarea solo necesita leer, usa `ai-data-reader` aunque haya otro broker abierto con más permisos. Así un error en una consulta no puede cambiar nada.

Cuando haga falta escribir, pregunta qué usuario usar si no está claro. No des por hecho que existe un usuario con permisos de escritura ni inventes su nombre.

## Scripts

`<SKILL_DIR>` es la carpeta de esta skill, normalmente `C:\Users\<usuario>\.claude\skills\sql-broker`. Al ejecutar cualquier comando, sustitúyela por la ruta absoluta real y literal (por ejemplo, en la línea que se lanza en la terminal del usuario no se pueden usar variables).

Están en `<SKILL_DIR>\scripts\`:

- `sql-broker.ps1 -Server <srv> -Database <bd> -User <usuario> [-AllowWrites]`: mantiene la conexión abierta. Lo arranca el usuario en el panel Terminal. Busca primero la credencial `sql-broker:<servidor>:<usuario>` en el Administrador de credenciales; si no existe, pide la contraseña por teclado.
- `check-credential.ps1 -Server <srv> -User <usuario>`: dice si esa credencial existe (`EXISTE …` / `NO EXISTE …`). No lee ni muestra la contraseña.
- `run-query.ps1 -Server <srv> -Database <bd> [-User <usuario>] -Sql "<consulta>"`: envía una consulta y muestra el estado y la tabla de resultados. Si no se indica `-User`, usa `ai-data-reader`.
- `run-query.ps1 -Server <srv> -Database <bd> [-User <usuario>] -Status`: comprueba si hay un broker conectado para ese usuario y en qué modo está.

Cada usuario tiene su propio broker y su propia cola, en `%USERPROFILE%\.sql-broker\<servidor>\<bd>\<usuario>\`:
- `inbox\`: consultas pendientes;
- `results\`: un `.csv` y un `.status.txt` por consulta;
- `ready.txt`: existe mientras el broker está conectado y guarda su PID y su modo.

Así puede haber a la vez un broker de lectura y otro de escritura.

**Otros límites:**
- Devuelve como máximo 1000 filas por consulta (`-MaxRows`).
- Cada consulta tiene un tiempo límite de 120 s (`-CommandTimeout`).
- En modo escritura no se reintenta automáticamente una sentencia si la conexión se corta: podría haberse aplicado ya.

## Flujo

### 1. Identificar la conexión y el usuario

Necesitas el servidor, la base de datos y el usuario. Si el usuario pega una cadena de conexión, sácalos de `Data Source`, `Initial Catalog` y `User ID`. Si falta `Initial Catalog`, pregunta a qué base de datos conectar: sin ella entraría en `master`.

Elige el usuario según la tabla de arriba.

**Si la cadena incluye una contraseña:** no la uses. Avisa al usuario en una frase de que ha quedado escrita en el chat y de que conviene cambiarla.

Conexiones conocidas:

| Servidor | Base de datos | Usuario | Modo | Notas |
|---|---|---|---|---|
| `miservidor.database.windows.net` | `mibasedatos` | `ai-data-reader` | Solo lectura | Ejemplo: sustituye por tus propios servidor, base de datos y usuario |

### 1 bis. Credencial guardada en Windows (opcional, evita escribir la contraseña)

El broker lee la contraseña de una credencial genérica del Administrador de credenciales de Windows cuyo destino (Dirección de red o Internet) es exactamente `sql-broker:<servidor>:<usuario>`, por ejemplo `sql-broker:miservidor.database.windows.net:ai-data-reader`. Se lee dentro del proceso del broker y no se imprime. Aplica a cualquier base de datos de ese servidor y usuario.

Antes de arrancar el broker, comprueba si existe (no lee la contraseña):

```powershell
& "<SKILL_DIR>\scripts\check-credential.ps1" -Server <servidor> -User <usuario>
```

- **`EXISTE …`:** arranca el broker como en el paso 3. Se conectará solo, sin que el usuario escriba nada, y la salida de su pestaña dirá *"Usando la credencial guardada …"*.
- **`NO EXISTE …`:** ofrece al usuario crearla, sin pedirle nunca la contraseña a él en el chat. Dile que lo haga en su terminal, con el servidor y el usuario de la conexión, y que borre después esa línea del historial:

  ```
  cmdkey /generic:sql-broker:<servidor>:<usuario> /user:<usuario> /pass:'LA_CONTRASEÑA'
  ```

  (comillas simples para que PowerShell no interprete caracteres como `}` o `$`; una `'` dentro de la contraseña se duplica). Más limpio todavía: Panel de control → Administrador de credenciales → Credenciales de Windows → Agregar una credencial genérica, con ese destino, el usuario y la contraseña. Si no la quiere guardar, el broker la pide por teclado como siempre.
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

Lánzalo con `run_in_terminal`. La línea tiene que ser literal: sin variables, sin pipes y con la ruta completa.

Solo lectura:

```
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "<SKILL_DIR>\scripts\sql-broker.ps1" -Server miservidor.database.windows.net -Database mibasedatos -User ai-data-reader
```

Con escrituras: el mismo comando, con `-User <usuario-con-permisos> -AllowWrites`. Antes de lanzarlo, avisa al usuario de que ese broker podrá modificar la base de datos.

Se usa `powershell.exe` (Windows PowerShell 5.1) porque trae `System.Data.SqlClient` de serie.

Después, si **no** hay credencial guardada (paso 1 bis), dile al usuario que vaya a esa pestaña (enlázala), escriba la contraseña y pulse Enter. Si la hay, el broker se conecta solo. En ambos casos debería ver *"Conectado a … (modo …)"*. Para la consulta: espera a que `-Status` confirme la conexión antes de seguir.

**No leas esa pestaña con `read_terminal`.** El usuario escribe ahí una contraseña y el clasificador del modo automático bloquea esa lectura. Para saber si ya está conectado, usa `-Status` (paso 2).

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

Recuerda al usuario que cierre la pestaña del broker con **Ctrl-C**, sobre todo si es un broker de escritura. Mientras esté abierta, cualquier proceso de su equipo que deje un `.sql` en la cola puede usar esa conexión.

## Alternativa sin contraseña: Entra ID

Si la cuenta de Entra ID del usuario tiene un usuario en la base de datos (`CREATE USER [correo] FROM EXTERNAL PROVIDER` + `db_datareader`), se puede conectar con un token:
1. Inicia sesión con la skill `azure-cli-session`.
2. Claude obtiene un token con `az account get-access-token --resource https://database.windows.net/`.

Así no hace falta broker. Ofrécelo si el usuario quiere evitar contraseñas del todo.
