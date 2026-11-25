const express = require('express');
const mongoose = require('mongoose');
const createCors = require('./middleware/cors');
const authRoutes = require('./routes/auth');
const reservationRoutes = require('./routes/reservations');

const app = express();
app.disable('x-powered-by');
app.use('/api', createCors());
app.use(express.json({ limit: '16kb' }));

app.get('/api/health', (req, res) => {
  res.json({
    status: 'ok',
    database: mongoose.connection.readyState === 1 ? 'connected' : 'disconnected',
  });
});

app.get('/api/ready', (req, res) => {
  const connected = mongoose.connection.readyState === 1;
  res.set('Cache-Control', 'no-store');
  res.status(connected ? 200 : 503).json({ status: connected ? 'ready' : 'unavailable' });
});

app.use('/api/auth', authRoutes);
app.use('/api/reservations', reservationRoutes);

app.use((req, res) => res.status(404).json({ message: 'Ruta no encontrada.' }));
app.use((error, req, res, next) => {
  if (error instanceof SyntaxError && 'body' in error) {
    return res.status(400).json({ message: 'El JSON enviado no es valido.' });
  }
  console.error(error);
  return res.status(500).json({ message: 'Error interno del servidor.' });
});

module.exports = app;
