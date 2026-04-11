const http = require('http');
const fs   = require('fs');
const path = require('path');
const { spawn } = require('child_process');

const PORT       = 3000;
const DATA_PATH  = process.env.DATA_PATH  || '/data';
const LOGS_PATH  = process.env.LOGS_PATH  || '/logs';
const MUSIC_PATH = process.env.MUSIC_PATH || '/music';

const RESULTS_FILE  = path.join(DATA_PATH, 'scan_results.json');
const PROGRESS_FILE = path.join(DATA_PATH, 'scan_progress.json');
const META_FILE     = path.join(DATA_PATH, 'scan_meta.json');

let scanProcess = null;

const MIME = {
  '.html': 'text/html; charset=utf-8',
  '.css':  'text/css; charset=utf-8',
  '.js':   'application/javascript; charset=utf-8',
  '.json': 'application/json',
  '.ico':  'image/x-icon',
};

// ── HELPERS ───────────────────────────────────────────────────────────────────
function readJSON(p, fb = null) {
  try { return JSON.parse(fs.readFileSync(p, 'utf8')); } catch { return fb; }
}

function sendJSON(res, data, status = 200) {
  res.writeHead(status, {
    'Content-Type': 'application/json',
    'Access-Control-Allow-Origin': '*',
  });
  res.end(JSON.stringify(data));
}

// ── API HANDLERS ──────────────────────────────────────────────────────────────

function handleResults(res) {
  sendJSON(res, {
    results: readJSON(RESULTS_FILE, []),
    meta:    readJSON(META_FILE, {}),
  });
}

function handleProgress(res) {
  sendJSON(res, readJSON(PROGRESS_FILE, { running: false }));
}

function handleScan(req, res) {
  let body = '';
  req.on('data', c => { body += c; });
  req.on('end', () => {
    if (scanProcess && !scanProcess.killed) {
      sendJSON(res, { error: 'Skan już trwa' }, 409);
      return;
    }

    let mode = 'incremental';
    try { mode = JSON.parse(body).mode || 'incremental'; } catch { /* ignore */ }

    // First scan ever → force full
    const cacheFile = path.join(DATA_PATH, 'scan_cache.json');
    if (!fs.existsSync(cacheFile) || !fs.existsSync(RESULTS_FILE)) mode = 'full';

    const args = mode === 'full' ? ['--full'] : [];

    // Write initial progress immediately so UI shows bar right away
    fs.writeFileSync(PROGRESS_FILE, JSON.stringify({
      running: true,
      total:   0,
      done:    0,
      skipped: 0,
      errors:  0,
      current: 'Uruchamianie...',
      started: new Date().toISOString(),
    }));

    const env = { ...process.env, DATA_PATH, LOGS_PATH, MUSIC_PATH };

    scanProcess = spawn('/bin/bash', ['/app/scan.sh', ...args], { env });

    scanProcess.stdout.on('data', d => process.stdout.write('[SCAN] ' + d));
    scanProcess.stderr.on('data', d => process.stderr.write('[SCAN ERR] ' + d));

    scanProcess.on('close', code => {
      console.log(`[SCAN] Zakończono z kodem: ${code}`);
      scanProcess = null;
    });

    scanProcess.on('error', err => {
      console.error('[SCAN] Błąd procesu:', err.message);
      fs.writeFileSync(PROGRESS_FILE, JSON.stringify({ running: false, error: err.message }));
      scanProcess = null;
    });

    sendJSON(res, { status: 'started', mode });
  });
}

function handleLog(res) {
  const logFile = path.join(LOGS_PATH, 'scan.log');
  try {
    res.writeHead(200, {
      'Content-Type': 'text/plain; charset=utf-8',
      'Access-Control-Allow-Origin': '*',
    });
    res.end(fs.readFileSync(logFile, 'utf8'));
  } catch {
    res.writeHead(404);
    res.end('Brak pliku logu');
  }
}

function handleStatus(res) {
  sendJSON(res, {
    scanning: scanProcess !== null,
    progress: readJSON(PROGRESS_FILE, { running: false }),
    meta:     readJSON(META_FILE, {}),
    uptime:   process.uptime(),
  });
}

// ── STATIC FILES ──────────────────────────────────────────────────────────────
function handleStatic(req, res) {
  const filePath = path.join('/app', req.url === '/' ? 'index.html' : req.url);
  const ext      = path.extname(filePath);

  fs.readFile(filePath, (err, data) => {
    if (err) { res.writeHead(404); res.end('404 Not Found'); return; }
    res.writeHead(200, { 'Content-Type': MIME[ext] || 'application/octet-stream' });
    res.end(data);
  });
}

// ── ROUTER ────────────────────────────────────────────────────────────────────
http.createServer((req, res) => {
  const url = req.url.split('?')[0];

  if (req.method === 'OPTIONS') {
    res.writeHead(204, {
      'Access-Control-Allow-Origin':  '*',
      'Access-Control-Allow-Methods': 'GET, POST',
      'Access-Control-Allow-Headers': 'Content-Type',
    });
    res.end();
    return;
  }

  if (url === '/api/results'  && req.method === 'GET')  return handleResults(res);
  if (url === '/api/progress' && req.method === 'GET')  return handleProgress(res);
  if (url === '/api/scan'     && req.method === 'POST') return handleScan(req, res);
  if (url === '/api/log'      && req.method === 'GET')  return handleLog(res);
  if (url === '/api/status'   && req.method === 'GET')  return handleStatus(res);

  handleStatic(req, res);
}).listen(PORT, () => {
  console.log(`[SERVER] Hi-Res Scanner na porcie ${PORT}`);
  console.log(`[SERVER] DATA_PATH=${DATA_PATH} | MUSIC_PATH=${MUSIC_PATH}`);
});
