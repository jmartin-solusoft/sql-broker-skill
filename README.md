# sql-broker (skill de Claude Code)

Skill para que Claude pueda consultar bases de datos **SQL Server / Azure SQL** sin llegar a manejar nunca la contraseña.

Funciona con un *broker* local: tú arrancas `sql-broker.ps1` en tu terminal, la contraseña se guarda solo en la memoria de ese proceso (o la lee del Administrador de credenciales de Windows) y la conexión queda abierta. Claude deja consultas `.sql` en una carpeta de cola y lee los resultados en CSV.

- Por defecto es **solo lectura** (con el usuario `ai-data-reader`, o sin `-AllowWrites`).
- Las escrituras requieren un usuario con permisos, `-AllowWrites` y confirmación explícita en cada sentencia.
- Máximo 1000 filas por consulta y 120 s de tiempo límite.

## Requisitos

- Windows con Windows PowerShell 5.1 (viene de serie).
- Claude Code.
- Acceso de red a tu servidor SQL (VPN o firewall, según el caso) y un usuario de base de datos propio.

## Instalación

Copia la carpeta `sql-broker` dentro de las skills de tu usuario:

```
%USERPROFILE%\.claude\skills\sql-broker\
```

Debe quedar así:

```
.claude\skills\sql-broker\SKILL.md
.claude\skills\sql-broker\scripts\sql-broker.ps1
.claude\skills\sql-broker\scripts\run-query.ps1
.claude\skills\sql-broker\scripts\check-credential.ps1
```

Reinicia Claude Code y escribe `/sql-broker`.

## Credencial (opcional, para no teclear la contraseña cada vez)

Guárdala una sola vez en el Administrador de credenciales de Windows, con el destino `sql-broker:<servidor>:<usuario>`. En tu terminal (no en el chat):

```powershell
cmdkey /generic:sql-broker:<servidor>:<usuario> /user:<usuario> /pass:'LA_CONTRASEÑA'
```

Después borra esa línea del historial de PowerShell. Si no la guardas, el broker te la pide por teclado.

## Uso

Dile a Claude a qué servidor y base de datos quieres conectar (por ejemplo `miservidor.database.windows.net` / `mibasedatos`). Claude te dirá qué comando lanzar en tu terminal, esperará a que el broker esté conectado y luego hará las consultas. Al terminar, cierra la pestaña del broker con Ctrl-C.

Los valores de `SKILL.md` (servidor, base de datos, tabla) son ejemplos: sustitúyelos por los tuyos.

## Seguridad

- Este repositorio **no contiene contraseñas ni datos de ningún cliente**.
- Mientras el broker está abierto, cualquier proceso de tu equipo que deje un `.sql` en la cola puede usar esa conexión. Ciérralo cuando termines, sobre todo si es un broker de escritura.
