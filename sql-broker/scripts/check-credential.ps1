# Comprueba si existe la credencial generica "sql-broker:<servidor>:<usuario>" en el Administrador de credenciales.
# Solo dice si existe y con que usuario esta guardada: NO lee ni muestra la contrasena.
# Salida: "EXISTE <destino> (usuario <usuario>)" (codigo 0) o "NO EXISTE <destino>" seguido del comando cmdkey
# ya montado para guardarla (codigo 1).
param(
    [Parameter(Mandatory)][string]$Server,
    [Parameter(Mandatory)][string]$User
)
if (-not ('SqlBrokerCredCheck' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class SqlBrokerCredCheck {
    [DllImport("advapi32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    static extern bool CredRead(string target, int type, int flags, out IntPtr cred);
    [DllImport("advapi32.dll")]
    static extern void CredFree(IntPtr cred);
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    struct CRED {
        public int Flags; public int Type; public string TargetName; public string Comment;
        public long LastWritten; public int BlobSize; public IntPtr Blob; public int Persist;
        public int AttributeCount; public IntPtr Attributes; public string TargetAlias; public string UserName;
    }
    // Devuelve el nombre de usuario guardado, o null si no existe. No toca el blob con la contrasena.
    public static string UserOf(string target) {
        IntPtr p;
        if (!CredRead(target, 1, 0, out p)) return null;
        try { return ((CRED)Marshal.PtrToStructure(p, typeof(CRED))).UserName ?? ""; }
        finally { CredFree(p); }
    }
}
'@
}
$target = "sql-broker:${Server}:${User}"
$stored = [SqlBrokerCredCheck]::UserOf($target)
if ($null -ne $stored) { Write-Host "EXISTE $target (usuario $stored)"; exit 0 }
Write-Host "NO EXISTE $target"
# Si no existe, el propio script deja listo el comando para guardarla. Claude debe ofrecerselo al usuario
# en un bloque de codigo bash, sin que el usuario lo pida (ver "1 bis" en SKILL.md). La contrasena nunca se pide en el chat.
Write-Host ""
Write-Host "OFRECER AL USUARIO (obligatorio, en un bloque bash, antes de arrancar el broker; solo sustituye LA_CONTRASENA y borrala del historial):"
Write-Host "cmdkey /generic:$target /user:$User /pass:'LA_CONTRASENA'"
exit 1
