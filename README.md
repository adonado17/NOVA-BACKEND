# NOVA Backend

API REST de NOVA Studio con Express y MongoDB Atlas. Incluye registro, contraseñas con bcrypt, JWT de dos horas y CRUD de solicitudes de cita. Frontend: [NOVA-FRONTEND](https://github.com/adonado17/NOVA-FRONTEND).

API publicada: [readiness](https://3.19.116.135/api/ready). Aplicación: [NOVA Studio](https://d1b5jy58q5q89g.cloudfront.net/).

## Inicio

Requiere Node.js `>=24.15.0 <25`, npm y acceso a MongoDB Atlas. Desde la raíz:

```powershell
npm ci
Copy-Item .env.example .env
```

Completa `.env`:

- `PORT`: puerto HTTP; predeterminado `3000`.
- `MONGODB_URI`: URI privada de Atlas; credenciales e IP autorizadas.
- `JWT_SECRET`: secreto aleatorio de al menos 32 caracteres.
- `CORS_ORIGINS`: orígenes permitidos, separados por comas.

```powershell
npm start
```

La API escucha en `http://localhost:3000`. `npm run dev` reinicia al guardar. Conecta MongoDB antes de escuchar y cierra conexiones al recibir `SIGTERM` o `SIGINT`. Mantén secretos y `.env` fuera de Git.

## CORS

Sin configuración, permite `http://localhost:4200` y `http://127.0.0.1:4200`. Una lista explícita reemplaza esos valores; una lista vacía rechaza orígenes cruzados. Usa orígenes completos sin rutas, comodines ni credenciales.

El preflight admite `GET, HEAD, POST, PUT, DELETE, OPTIONS` y las cabeceras `Authorization` y `Content-Type`. Devuelve el origen permitido y `Vary: Origin`, sin habilitar cookies. Un origen rechazado recibe `403`; las peticiones sin `Origin` siguen disponibles.

Configura la URL de esta API o un proxy en el frontend. El prefijo es `/api`. CORS no sustituye la autorización JWT.

## Endpoints

| Método | Ruta | Resultado |
| --- | --- | --- |
| GET | `/api/health` | 200, salud y conexión MongoDB |
| GET | `/api/ready` | 200 conectado; 503 desconectado |
| POST | `/api/auth/register` | 201, usuario y JWT |
| POST | `/api/auth/login` | 200, usuario y JWT |
| GET | `/api/auth/me` | 200, perfil |
| GET | `/api/reservations` | 200, listar propias |
| GET | `/api/reservations/:id` | 200, consultar propia |
| POST | `/api/reservations` | 201, crear pendiente |
| PUT | `/api/reservations/:id` | 200, actualizar propia |
| DELETE | `/api/reservations/:id` | 204, eliminar propia |

Registro recibe `name, email, password`; login, `email, password`. Perfil y citas requieren `Authorization: Bearer TU_TOKEN`.

Las citas reciben `service` (`limpieza`, `hidratacion`, `masaje` o `corporal`), `scheduledAt` (fecha ISO futura) y `notes` opcional, máximo 500 caracteres. El propietario procede del token. Errores: `401` autenticación, `404` cita ajena/inexistente, `409` correo duplicado, `422` datos inválidos.

Las solicitudes quedan pendientes de confirmación. No hay administración de servicios ni confirmación de disponibilidad.

## Pruebas

```powershell
npm test
```

Usan modelos simulados en memoria: autenticación, CRUD, aislamiento, disponibilidad y CORS. No verifican Atlas real; compruébalo con `/api/health` y `/api/ready`. Colección manual: `postman/NOVA-Studio.postman_collection.json`.

## EC2

Instala dependencias con `npm ci --omit=dev`. Configura un servicio con este directorio como `WorkingDirectory`, `src/server.js` como entrada, Node 24, `NODE_ENV=production` y las variables privadas anteriores.

El despliegue independiente está activo en EC2, región Ohio (`us-east-2`). Nginx sirve HTTPS y envía `/api` a `127.0.0.1:3000`; `nova.service` mantiene la API. Atlas permite la IP fija del servidor y las variables privadas se conservan en el entorno del servicio. El frontend se sirve desde S3 mediante CloudFront, y las páginas de la dirección anterior de EC2 redirigen a esa aplicación.

En producción, `CORS_ORIGINS` incluye `https://d1b5jy58q5q89g.cloudfront.net`, además de los orígenes locales y de la instancia autorizados. El token permite que cada usuario opere únicamente sus propias citas.

- [Empaquetado y activación de la API](deploy/aws/README.md).
- [Acceso SSH y sesión de MobaXterm para el taller](deploy/aws/README-SSH.md).

La comprobación del despliegue separado completó 83 verificaciones de rutas, archivos, HTTPS, salud y CORS. Una comprobación adicional completó 120 verificaciones de autenticación, CRUD y aislamiento con Atlas real; eliminó los dos usuarios temporales y la cita que creó. Estos resultados corresponden al despliegue del 24 de noviembre de 2026, no sustituyen las pruebas tras futuros cambios.

## Recorrido del código

1. `src/server.js`: valida la configuración privada, conecta Atlas y empieza a escuchar.
2. `src/app.js`: crea Express y registra middleware y rutas.
3. `src/routes/auth.js` y `src/controllers/auth.controller.js`: registro, login y perfil; contraseña con hash y emisión del JWT.
4. `src/middleware/auth.js`: valida el JWT antes de permitir perfil y citas.
5. `src/models/User.js` y `src/models/Reservation.js`: estructura e índices de los documentos.
6. `src/validators/reservation.validator.js`: valida servicio, fecha y notas.
7. `src/routes/reservations.js` y `src/controllers/reservation.controller.js`: operaciones del CRUD. Los filtros incluyen `user: req.user.id` para limitar cada operación al propietario.
8. `src/middleware/cors.js`: controla los orígenes web que pueden llamar a la API desde el navegador.

En una demostración, crea una cuenta de prueba desde el frontend, inicia sesión y crea, edita y elimina una cita de esa cuenta. Después muestra el servicio Angular que envía la petición y el controlador Express que consulta MongoDB. No muestres `.env`, claves privadas ni tokens.
