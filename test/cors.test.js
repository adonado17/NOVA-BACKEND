const { test } = require('node:test');
const assert = require('node:assert/strict');
const express = require('express');
const request = require('supertest');
const app = require('../src/app');
const createCors = require('../src/middleware/cors');

test('CORS permite ambos orígenes locales y conserva las llamadas sin Origin', async () => {
  for (const origin of ['http://localhost:4200', 'http://127.0.0.1:4200']) {
    const response = await request(app).get('/api/health').set('Origin', origin);
    assert.equal(response.status, 200);
    assert.equal(response.headers['access-control-allow-origin'], origin);
    assert.match(response.headers.vary, /\bOrigin\b/i);
    assert.equal(response.headers['access-control-allow-credentials'], undefined);
  }
  const response = await request(app).get('/api/health');
  assert.equal(response.status, 200);
  assert.equal(response.headers['access-control-allow-origin'], undefined);
  const head = await request(app).head('/api/health').set('Origin', 'http://localhost:4200');
  assert.equal(head.status, 200);
  assert.equal(head.headers['access-control-allow-origin'], 'http://localhost:4200');
});

test('CORS rechaza orígenes ajenos antes de ejecutar la ruta', async () => {
  for (const origin of ['https://example.com', 'http://localhost:4200.evil.example', 'null']) {
    const response = await request(app).post('/api/auth/register').set('Origin', origin).send({});
    assert.equal(response.status, 403);
    assert.equal(response.body.message, 'Origen no permitido.');
    assert.equal(response.headers['access-control-allow-origin'], undefined);
    assert.match(response.headers.vary, /\bOrigin\b/i);
  }
});

test('preflight permite JSON y Bearer sin exigir token y sin habilitar cookies', async () => {
  const response = await request(app).options('/api/reservations')
    .set('Origin', 'http://localhost:4200')
    .set('Access-Control-Request-Method', 'PUT')
    .set('Access-Control-Request-Headers', 'Content-Type, Authorization');
  assert.equal(response.status, 204);
  assert.equal(response.headers['access-control-allow-origin'], 'http://localhost:4200');
  assert.match(response.headers['access-control-allow-methods'], /\bPUT\b/);
  assert.equal(response.headers['access-control-allow-headers'], 'Authorization, Content-Type');
  assert.equal(response.headers['access-control-allow-credentials'], undefined);
  for (const field of ['Origin', 'Access-Control-Request-Method', 'Access-Control-Request-Headers']) {
    assert.ok(response.headers.vary.toLowerCase().includes(field.toLowerCase()));
  }
  assert.equal((await request(app).get('/api/reservations').set('Origin', 'http://localhost:4200')).status, 401);
});

test('preflight rechaza métodos o cabeceras no previstos', async () => {
  for (const [method, headers] of [['PATCH', 'Authorization'], ['POST', 'X-Admin']]) {
    const response = await request(app).options('/api/reservations')
      .set('Origin', 'http://localhost:4200')
      .set('Access-Control-Request-Method', method)
      .set('Access-Control-Request-Headers', headers);
    assert.equal(response.status, 403);
  }
});

test('CORS_ORIGINS admite una lista explícita y no añade los valores locales', async () => {
  const configuredApp = express();
  configuredApp.use(createCors('https://nova.example, https://www.nova.example'));
  configuredApp.get('/api/health', (req, res) => res.json({ status: 'ok' }));
  for (const origin of ['https://nova.example', 'https://www.nova.example']) {
    const response = await request(configuredApp).get('/api/health').set('Origin', origin);
    assert.equal(response.status, 200);
    assert.equal(response.headers['access-control-allow-origin'], origin);
  }
  assert.equal((await request(configuredApp).get('/api/health').set('Origin', 'http://localhost:4200')).status, 403);
  for (const origin of ['*', 'https://*.example.com', 'null', 'https://user:password@example.com', 'https://nova.example/login']) {
    assert.throws(() => createCors(origin), /CORS_ORIGINS/);
  }
});
