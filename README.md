# NOVA Backend

API independiente de NOVA Studio, construida con Node.js, Express y MongoDB Atlas. Gestiona cuentas de clientes y solicitudes de cita. La interfaz Angular se mantiene en [NOVA-FRONTEND](https://github.com/adonado17/NOVA-FRONTEND).

## Funciones

- Registro con validación y hash de contraseña mediante bcrypt.
- Inicio de sesión y perfil protegido con JWT de dos horas de vigencia.
- Crear, listar, consultar, actualizar y eliminar las solicitudes de cita propias.
- Comprobación de salud y disponibilidad de la conexión a MongoDB.
- CORS con lista explícita de orígenes para conectar el frontend separado.

Las solicitudes quedan pendientes de confirmación. La gestión administrativa de servicios y la confirmación de disponibilidad no están implementadas.

## Instalación y ejecución local

Se requiere Node.js 24.15 o posterior dentro de la versión 24, npm y una conexión MongoDB Atlas con usuario de base de datos e IP autorizada.

Ejecuta los comandos desde la raíz de este repositorio:

```powershell
npm ci
Copy-Item .env.example .env
```

Completa las variables de tu archivo privado `.env`:

| Variable | Uso |
| --- | --- |
| `PORT` | Puerto del servidor; predeterminado: `3000`. |
| `MONGODB_URI` | URI privada de MongoDB Atlas. Codifica los caracteres especiales de la contraseña si la URI los requiere. |
| `JWT_SECRET` | Secreto aleatorio de al menos 32 caracteres para firmar y verificar los tokens. Reemplaza el marcador del ejemplo. |
| `CORS_ORIGINS` | Orígenes completos del frontend permitidos, separados por comas, sin rutas. |

```powershell
npm start
```

La API escucha en `http://localhost:3000`. Para reiniciar automáticamente al guardar cambios, utiliza `npm run dev`.

El servidor conecta primero con MongoDB y luego empieza a aceptar peticiones. Al recibir `SIGTERM` o `SIGINT`, deja de aceptar conexiones y cierra la conexión de base de datos. Este repositorio no necesita una compilación de Angular para arrancar; sus rutas publican JSON, no páginas HTML.

## Conexión con el frontend y CORS

Si `CORS_ORIGINS` no está definida, se permiten `http://localhost:4200` y `http://127.0.0.1:4200`. Una lista configurada reemplaza esos valores. Por ejemplo:

```dotenv
CORS_ORIGINS=http://localhost:4200,http://127.0.0.1:4200
```

Para producción, establece el origen HTTPS real donde publiques NOVA-FRONTEND. El origen incluye protocolo, nombre y puerto cuando corresponda; no incluye la ruta de una página. No se aceptan comodines ni credenciales dentro del origen. Una lista vacía no autoriza orígenes cruzados.

La API responde al preflight de los métodos `GET`, `HEAD`, `POST`, `PUT`, `DELETE` y `OPTIONS`, y admite las cabeceras `Authorization` y `Content-Type`. Refleja únicamente el origen permitido y añade `Vary: Origin`; no habilita cookies mediante `Access-Control-Allow-Credentials`. Un origen no permitido recibe `403`. Las llamadas sin cabecera `Origin`, como las habituales de Postman, siguen disponibles.

CORS controla el acceso de navegadores entre orígenes; las operaciones protegidas continúan exigiendo JWT y autorización por usuario. El frontend debe apuntar a la dirección de esta API mediante su configuración de URL o un proxy de desarrollo. Las rutas conservan el prefijo `/api`.

## Endpoints

| Método | Ruta | Respuesta |
| --- | --- | --- |
| GET | `/api/health` | `200`, estado de la API y conexión a MongoDB. |
| GET | `/api/ready` | `200` si MongoDB está conectado; `503` en otro caso. |
| POST | `/api/auth/register` | `201`, usuario público y JWT. |
| POST | `/api/auth/login` | `200`, usuario público y JWT. |
| GET | `/api/auth/me` | `200`, perfil del usuario autenticado. |
| GET | `/api/reservations` | `200`, solicitudes propias. |
| GET | `/api/reservations/:id` | `200`, una solicitud propia. |
| POST | `/api/reservations` | `201`, nueva solicitud pendiente. |
| PUT | `/api/reservations/:id` | `200`, solicitud propia actualizada. |
| DELETE | `/api/reservations/:id` | `204`, solicitud propia eliminada. |

Registro: envía `name`, `email` y `password` en JSON. Inicio de sesión: envía `email` y `password`. Para el perfil y todas las operaciones de citas, utiliza `Authorization: Bearer TU_TOKEN`.

Crear o editar una cita requiere `service` (`limpieza`, `hidratacion`, `masaje` o `corporal`) y `scheduledAt` (fecha ISO futura); `notes` es opcional y admite hasta 500 caracteres. El servidor asigna el propietario desde el token. Una solicitud ajena o inexistente devuelve `404`; un token ausente o inválido, `401`; los datos inválidos, `422`; y un correo ya registrado, `409`.

## Organización y pruebas

`src/routes/` define endpoints; `controllers/` ejecuta operaciones; `validators/` define las reglas de entrada; `middleware/` contiene CORS, validación y autenticación; `models/` describe usuarios y citas; `config/` reúne conexión y configuración del negocio. `src/app.js` configura Express y `src/server.js` inicia el proceso.

```powershell
npm test
```

Las pruebas usan modelos simulados en memoria, sin credenciales de Atlas. Cubren autenticación, CRUD y separación por usuario, disponibilidad, ejecución de producción sin frontend y CORS con orígenes permitidos/rechazados y preflight. La conexión real a Atlas se comprueba por separado con `/api/health` y `/api/ready` al ejecutar el servidor.

Para pruebas manuales, importa `postman/NOVA-Studio.postman_collection.json` y ajusta su dirección base al servidor que quieras revisar.

## Preparación para un servidor EC2

La separación de repositorios no modifica el despliegue AWS existente. Para publicar este backend por separado, prepara su directorio propio e instala únicamente dependencias de producción con `npm ci --omit=dev`.

Un servicio de sistema debe usar como `WorkingDirectory` la raíz de NOVA-BACKEND y ejecutar `node /RUTA/NOVA-BACKEND/src/server.js`. Configura `NODE_ENV=production`, `PORT`, `MONGODB_URI`, `JWT_SECRET` y `CORS_ORIGINS` mediante el entorno privado del servidor. Si utilizas Node 24 con un ejecutable específico del sistema, configura esa ruta en `ExecStart`.

Nginx puede publicar HTTPS y reenviar a `http://127.0.0.1:3000`. Autoriza la IP de salida del servidor en Atlas y configura en el frontend la URL HTTPS de la API. Verifica `/api/ready` antes de enviar tráfico; no expongas el puerto interno de Node si el acceso público pasa por el proxy.

## Variables privadas

No publiques `.env`, contraseñas, tokens, claves privadas ni credenciales AWS. `.env.example` contiene solo marcadores de configuración. `.gitignore` excluye variables privadas, dependencias, claves habituales y resultados locales. Mantén los secretos reales fuera del repositorio y de cualquier archivo de entrega.
