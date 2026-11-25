const defaultOrigins = ['http://localhost:4200', 'http://127.0.0.1:4200'];
const methods = ['GET', 'HEAD', 'POST', 'PUT', 'DELETE', 'OPTIONS'];
const headers = ['authorization', 'content-type'];

function createCors(configuredOrigins = process.env.CORS_ORIGINS) {
  const entries = configuredOrigins === undefined
    ? defaultOrigins
    : configuredOrigins.split(',').map((origin) => origin.trim()).filter(Boolean);
  const origins = new Set(entries.map((origin) => {
    let url;
    try {
      url = new URL(origin);
    } catch {
      throw new Error('CORS_ORIGINS debe contener orígenes HTTP o HTTPS separados por comas.');
    }
    if (!['http:', 'https:'].includes(url.protocol) || url.hostname.includes('*') || url.username || url.password
      || url.pathname !== '/' || url.search || url.hash) {
      throw new Error('CORS_ORIGINS no admite comodines, credenciales, rutas ni parámetros.');
    }
    return url.origin;
  }));

  return function cors(req, res, next) {
    res.vary('Origin');
    const origin = req.get('Origin');
    if (!origin) return next();
    if (!origins.has(origin)) {
      return res.status(403).json({ message: 'Origen no permitido.' });
    }

    res.set('Access-Control-Allow-Origin', origin);
    if (req.method !== 'OPTIONS' || !req.get('Access-Control-Request-Method')) return next();

    res.vary('Access-Control-Request-Method');
    res.vary('Access-Control-Request-Headers');
    const requestedMethod = req.get('Access-Control-Request-Method');
    const requestedHeaders = (req.get('Access-Control-Request-Headers') || '')
      .split(',').map((header) => header.trim().toLowerCase()).filter(Boolean);
    if (!methods.includes(requestedMethod) || requestedHeaders.some((header) => !headers.includes(header))) {
      return res.status(403).json({ message: 'Método o cabeceras CORS no permitidos.' });
    }

    res.set('Access-Control-Allow-Methods', methods.join(', '));
    res.set('Access-Control-Allow-Headers', 'Authorization, Content-Type');
    return res.status(204).end();
  };
}

module.exports = createCors;
