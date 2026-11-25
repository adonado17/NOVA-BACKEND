# NOVA Backend

API REST de NOVA Studio con Express y MongoDB Atlas. Incluye registro, contraseñas con bcrypt, JWT de dos horas y CRUD de solicitudes de cita. Frontend: [NOVA-FRONTEND](https://github.com/adonado17/NOVA-FRONTEND).

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

Publica HTTPS mediante Nginx hacia `127.0.0.1:3000`, autoriza la IP del servidor en Atlas y configura el origen HTTPS del frontend. Comprueba readiness antes de enviar tráfico. El despliegue independiente de este repositorio en EC2 está pendiente.
