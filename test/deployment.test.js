const { test } = require('node:test');
const assert = require('node:assert/strict');
const { spawnSync } = require('node:child_process');
const mongoose = require('mongoose');
const request = require('supertest');
const app = require('../src/app');

test('readiness deja de aceptar tráfico cuando MongoDB no está conectado', async () => {
  const originalState = mongoose.connection.readyState;
  try {
    for (const state of [0, 2, 3, 1]) {
      mongoose.connection.readyState = state;
      const response = await request(app).get('/api/ready');
      assert.equal(response.status, state === 1 ? 200 : 503);
      assert.equal(response.headers['cache-control'], 'no-store');
      assert.equal(response.body.status, state === 1 ? 'ready' : 'unavailable');
    }
  } finally {
    mongoose.connection.readyState = originalState;
  }
});

test('producción carga la API sin depender de Angular compilado', () => {
  const result = spawnSync(process.execPath, ['-e', `
    const assert = require('node:assert/strict');
    const request = require('supertest');
    const app = require('./src/app');
    (async () => {
      assert.equal((await request(app).get('/api/health')).status, 200);
      const page = await request(app).get('/login');
      assert.equal(page.status, 404);
      assert.deepEqual(page.body, { message: 'Ruta no encontrada.' });
    })().catch(() => { process.exitCode = 1; });
  `], {
    cwd: require('node:path').resolve(__dirname, '..'),
    env: { ...process.env, NODE_ENV: 'production' },
    encoding: 'utf8',
  });
  assert.equal(result.status, 0, result.stderr);
});

test('la API no publica las páginas ni los recursos del frontend', async () => {
  for (const route of ['/', '/login', '/register', '/profile', '/reservations', '/registro.html', '/css/styles.css']) {
    const response = await request(app).get(route);
    assert.equal(response.status, 404);
    assert.match(response.headers['content-type'], /application\/json/);
    assert.deepEqual(response.body, { message: 'Ruta no encontrada.' });
  }
});
