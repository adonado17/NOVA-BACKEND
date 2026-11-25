# SSH para el taller

El script de preparación utiliza la EC2 existente. Systems Manager permanece disponible; el script no crea usuarios, claves privadas ni instancias. La clave privada se genera y conserva en el equipo local.

## Regla de red

Despliega `ssh-access.yaml` como un stack separado llamado `nova-class-ssh`, pasando el grupo de seguridad existente en `GroupId` y la IP pública actual del equipo con `/32` en `ClientIpv4Cidr`. La plantilla contiene únicamente una regla TCP 22. No actualiza ni reemplaza el stack `nova-production`.

## Clave y servidor

Genera y conserva localmente una clave RSA de 3072 bits con comentario `NOVA-classkey`. Codifica en Base64 únicamente la línea de su archivo público `.pub`.

Ejecuta mediante SSM, como root:

```bash
bash setup-ssh.sh PUBLIC_KEY_BASE64 [HUELLA_SHA256_DEL_HOST_ESPERADA]
```

El argumento opcional es la huella completa `SHA256:...`; si difiere, el script se detiene antes de autorizar la clave. El script valida el formato y tamaño de la clave pública, el usuario `ec2-user`, su home y las rutas sin enlaces simbólicos. Conserva las claves existentes y añade la nueva una sola vez, con `.ssh` en 700 y `authorized_keys` en 600. Si la clave ya existe con opciones restrictivas, no añade otra copia sin esas opciones.

Comprueba `sshd -t`, autenticación por clave habilitada, contraseñas e interacción de teclado deshabilitadas y compatibilidad RSA SHA-2. No cambia `sshd_config`, no habilita acceso root y conserva su valor restrictivo existente; admite, por ejemplo, `prohibit-password`. Inicia `sshd.service` solo si estaba inactivo.

Devuelve la clave pública Ed25519 del host y su huella. Compara esa huella obtenida por SSM con la mostrada por MobaXterm antes de aceptar la primera conexión. Usa `ec2-user`, puerto 22 y la clave privada local; no compartas esa clave ni la subas al repositorio.

## Sesión de MobaXterm

En MobaXterm, crea una sesión con **Session → SSH**:

| Campo | Valor |
| --- | --- |
| Remote host | `3.19.116.135` |
| Specify username | `ec2-user` |
| Port | `22` |
| Advanced SSH settings → Use private key | Archivo privado `.pem` guardado localmente |
| Nombre del marcador | `NOVA EC2 - Taller` |

En la primera conexión, verifica la identidad del servidor antes de guardar su clave. La huella Ed25519 obtenida por SSM para esta instancia es:

```text
SHA256:LvVTvgfzcS8vw1jUSygpSLhCNY3KmqSMKgxldRLCLMM
```

MobaXterm sirve para entrar por SSH al Linux de EC2 y revisar el proceso de la API, los archivos y los registros. El frontend sigue publicado en S3 y CloudFront; abrir esta sesión no cambia su alojamiento. Los comandos de consulta están en [Activación de la API en EC2](README.md#comprobaciones-desde-el-servidor).

La regla depende de la IP pública del equipo. Si cambia, debe revisarse el `/32`. Eliminar el stack `nova-class-ssh` retira esa regla adicional, sin eliminar la EC2 ni las claves autorizadas.

Referencias: [CloudFormation SecurityGroupIngress](https://docs.aws.amazon.com/AWSCloudFormation/latest/TemplateReference/aws-resource-ec2-securitygroupingress.html), [sshd](https://man.openbsd.org/sshd.8), [ssh-keygen](https://man.openbsd.org/ssh-keygen.1).
