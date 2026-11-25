# Activación de la API en EC2

## Despliegue activo

La API independiente responde en `https://3.19.116.135/api`, en la EC2 existente de Ohio (`us-east-2`). El frontend está publicado en `https://d1b5jy58q5q89g.cloudfront.net/`, con archivos almacenados en S3. Nginx conserva el certificado HTTPS de la instancia y envía únicamente la API al proceso de Node.

La versión activa se referencia mediante `/opt/nova/current-api`. La unidad es `nova.service`, con entrada `src/server.js` y puerto 3000. Su entorno privado activo es `/etc/nova/api.env`, fuera del repositorio. `/etc/nova/nova.env` se conserva como origen privado de la configuración anterior.

## Paquete del backend

Desde la raíz del repositorio, en PowerShell 7:

```powershell
./scripts/package-aws.ps1
```

Genera `outputs/nova-backend.zip` con `package.json`, `package-lock.json` y `src/` tomados del commit actual. Rechaza cambios sin commit en esos archivos, rutas no permitidas, claves y credenciales incrustadas. Valida el lockfile sin instalar dependencias, mediante `npm ci --dry-run --offline`; necesita la caché local de npm disponible. El directorio `outputs/` está excluido de Git.

Solo se empaqueta el runtime. Las guías, las pruebas, el frontend y la configuración privada no forman parte del ZIP.

## Activación

Este script utiliza la instancia existente de NOVA y se ejecuta como root mediante SSM. No crea recursos, abre SSH ni emite certificados. Conserva `/etc/nova/nova.env`, los archivos del certificado y la renovación existente.

El ZIP debe contener `package.json`, `package-lock.json` y `src/` en la raíz, sin `.env`, claves o `node_modules`. El rol existente necesita permiso de lectura del objeto S3 elegido.

```bash
bash activate.sh prepare BUCKET KEY us-east-2 https://DISTRIBUCION.cloudfront.net SHA256_DEL_ZIP
```

Instala dependencias de producción en `/opt/nova/api-releases/`, crea una copia privada del entorno y verifica la candidata en el puerto 3001. `nova.service`, el puerto 3000 y la portada actual permanecen sin cambios. La candidata no se habilita al arrancar la instancia.

El SHA256 opcional verifica los bytes descargados antes de extraer el ZIP. `CORS_ORIGINS` admite varios orígenes separados por comas dentro de un único argumento.

Cuando el frontend responda por HTTPS:

```bash
bash activate.sh cutover https://DISTRIBUCION.cloudfront.net 3.19.116.135
```

Exige que ese origen esté permitido por la candidata y que devuelva Angular. Apunta `/opt/nova/current-api` a la versión preparada, cambia `nova.service` a `src/server.js` en el puerto 3000 y verifica readiness, HTTPS y preflight CORS. Nginx conserva TLS y ACME, mantiene `/api` y `/api/` como proxy y redirige el resto al frontend con 302. La candidata se detiene al terminar.

Los enlaces antiguos `/registro.html`, `/iniciar-sesion.html` y `/perfil.html` se redirigen a `/register`, `/login` y `/profile` del frontend, conservando la consulta de la URL.

Un fallo restaura la unidad, el entorno, el enlace y Nginx anteriores, y comprueba readiness. Las copias de rollback y el estado se guardan bajo `/var/lib/nova-api-deploy/`, propiedad de root con permisos privados. La versión monorepo original no se elimina.

Validación local, sin AWS:

```bash
bash -n deploy/aws/activate.sh
python deploy/aws/test_activate.py
```

Las fixtures verifican validación de argumentos y ZIP, copia del entorno y transformación de Nginx. No sustituyen las comprobaciones de servicios, TLS, Atlas y acceso externo durante la activación real.

## Comprobaciones desde el servidor

Después de entrar por SSH con `ec2-user`, estos comandos permiten revisar el despliegue sin cambiar los datos:

```bash
cd /opt/nova/current-api
node --version
sudo systemctl status nova.service --no-pager
curl --fail --silent http://127.0.0.1:3000/api/ready
curl --fail --silent https://3.19.116.135/api/health
sudo nginx -t
sudo journalctl -u nova.service -n 30 --no-pager
sed -n '1,120p' src/server.js
```

Para sustentar el código, abre también `src/controllers/reservation.controller.js` y muestra cómo cada consulta incluye el usuario del token. El frontend se revisa en su repositorio separado: `src/app/services/reservation.service.ts` envía las peticiones a esta API.
