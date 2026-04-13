const http = require('http');
const fs   = require('fs');
const path = require('path');
const { spawn } = require('child_process');

const PORT       = 3000;
const DATA_PATH  = process.env.DATA_PATH  || '/data';
const LOGS_PATH  = process.env.LOGS_PATH  || '/logs';
const MUSIC_PATH = process.env.MUSIC_PATH || '/music';

const RESULTS_FILE   = path.join(DATA_PATH, 'scan_results.json');
const PROGRESS_FILE  = path.join(DATA_PATH, 'scan_progress.json');
const META_FILE      = path.join(DATA_PATH, 'scan_meta.json');
const OVERRIDES_FILE = path.join(DATA_PATH, 'overrides.json');

let scanProcess = null;

const MIME = {
  '.html': 'text/html; charset=utf-8',
  '.css':  'text/css; charset=utf-8',
  '.js':   'application/javascript; charset=utf-8',
  '.json': 'application/json',
  '.ico':  'image/x-icon',
};

function readJSON(p, fb = null) {
  try { return JSON.parse(fs.readFileSync(p, 'utf8')); } catch { return fb; }
}

function writeJSON(p, data) {
  fs.writeFileSync(p, JSON.stringify(data, null, 2));
}

function sendJSON(res, data, status = 200) {
  res.writeHead(status, { 'Content-Type': 'application/json', 'Access-Control-Allow-Origin': '*' });
  res.end(JSON.stringify(data));
}

function parseBody(req) {
  return new Promise(resolve => {
    let b = '';
    req.on('data', c => { b += c; });
    req.on('end', () => { try { resolve(JSON.parse(b)); } catch { resolve({}); } });
  });
}

// ── API HANDLERS ──────────────────────────────────────────────────────────────

function handleResults(res) {
  sendJSON(res, {
    results:   readJSON(RESULTS_FILE, []),
    meta:      readJSON(META_FILE, {}),
    overrides: readJSON(OVERRIDES_FILE, {}),
  });
}

function handleProgress(res) {
  sendJSON(res, readJSON(PROGRESS_FILE, { running: false }));
}

function startScanProcess(args, mode) {
  const env = { ...process.env, DATA_PATH, LOGS_PATH, MUSIC_PATH };

  // Write initial progress immediately
  fs.writeFileSync(PROGRESS_FILE, JSON.stringify({
    running: true, total: 0, done: 0, skipped: 0, errors: 0,
    current: 'Uruchamianie...', started: new Date().toISOString(),
  }));

  scanProcess = spawn('/bin/bash', ['/app/scan.sh', ...args], { env });
  scanProcess.stdout.on('data', d => process.stdout.write('[SCAN] ' + d));
  scanProcess.stderr.on('data', d => process.stderr.write('[SCAN ERR] ' + d));
  scanProcess.on('close', code => { console.log(`[SCAN] code: ${code}`); scanProcess = null; });
  scanProcess.on('error', err => {
    console.error('[SCAN] error:', err.message);
    fs.writeFileSync(PROGRESS_FILE, JSON.stringify({ running: false, error: err.message }));
    scanProcess = null;
  });
}

async function handleScan(req, res) {
  if (scanProcess && !scanProcess.killed) {
    sendJSON(res, { error: 'Skan juz trwa' }, 409); return;
  }
  const body = await parseBody(req);
  let mode = body.mode || 'incremental';

  const cacheFile = path.join(DATA_PATH, 'scan_cache.json');
  if (!fs.existsSync(cacheFile) || !fs.existsSync(RESULTS_FILE)) mode = 'full';

  const args = mode === 'full' ? ['--full'] : [];
  startScanProcess(args, mode);
  sendJSON(res, { status: 'started', mode });
}

async function handleScanOne(req, res) {
  if (scanProcess && !scanProcess.killed) {
    sendJSON(res, { error: 'Skan juz trwa' }, 409); return;
  }
  const body = await parseBody(req);
  const dir = body.path;
  if (!dir) { sendJSON(res, { error: 'Brak pola path' }, 400); return; }

  startScanProcess(['--dir', dir], 'single');
  sendJSON(res, { status: 'started', mode: 'single', path: dir });
}

function handleStop(res) {
  if (!scanProcess || scanProcess.killed) {
    sendJSON(res, { error: 'Brak aktywnego skanu' }, 404); return;
  }
  scanProcess.kill('SIGTERM');
  sendJSON(res, { status: 'stopping' });
}

async function handleOverride(req, res) {
  const body = await parseBody(req);
  const { path: albumPath, status, confidence } = body;
  if (!albumPath || !status) { sendJSON(res, { error: 'Brak path lub status' }, 400); return; }

  const overrides = readJSON(OVERRIDES_FILE, {});
  overrides[albumPath] = { status, confidence: confidence || 'Recznie ustawiony', setAt: new Date().toISOString() };
  writeJSON(OVERRIDES_FILE, overrides);

  // Update result in results file immediately
  const results = readJSON(RESULTS_FILE, []);
  const idx = results.findIndex(r => r.path === albumPath);
  if (idx >= 0) {
    results[idx].status     = status;
    results[idx].confidence = confidence || 'Recznie ustawiony';
    results[idx].manual     = true;
    writeJSON(RESULTS_FILE, results);
  }
  sendJSON(res, { ok: true });
}

async function handleOverrideDelete(req, res) {
  const body = await parseBody(req);
  const { path: albumPath } = body;
  if (!albumPath) { sendJSON(res, { error: 'Brak path' }, 400); return; }

  const overrides = readJSON(OVERRIDES_FILE, {});
  delete overrides[albumPath];
  writeJSON(OVERRIDES_FILE, overrides);

  sendJSON(res, { ok: true });
}

function handleLog(res) {
  const logFile = path.join(LOGS_PATH, 'scan.log');
  try {
    res.writeHead(200, { 'Content-Type': 'text/plain; charset=utf-8', 'Access-Control-Allow-Origin': '*' });
    res.end(fs.readFileSync(logFile, 'utf8'));
  } catch { res.writeHead(404); res.end('Brak pliku logu'); }
}

function handleStatus(res) {
  sendJSON(res, {
    scanning: scanProcess !== null,
    progress: readJSON(PROGRESS_FILE, { running: false }),
    meta:     readJSON(META_FILE, {}),
    uptime:   process.uptime(),
  });
}

function handleStatic(req, res) {
  const filePath = path.join('/app', req.url === '/' ? 'index.html' : req.url);
  const ext = path.extname(filePath);
  fs.readFile(filePath, (err, data) => {
    if (err) { res.writeHead(404); res.end('404'); return; }
    res.writeHead(200, { 'Content-Type': MIME[ext] || 'application/octet-stream' });
    res.end(data);
  });
}

// ── ROUTER ────────────────────────────────────────────────────────────────────
http.createServer((req, res) => {
  const url = req.url.split('?')[0];

  if (req.method === 'OPTIONS') {
    res.writeHead(204, { 'Access-Control-Allow-Origin': '*', 'Access-Control-Allow-Methods': 'GET,POST,DELETE', 'Access-Control-Allow-Headers': 'Content-Type' });
    res.end(); return;
  }

  if (url === '/api/results'         && req.method === 'GET')    return handleResults(res);
  if (url === '/api/progress'        && req.method === 'GET')    return handleProgress(res);
  if (url === '/api/scan'            && req.method === 'POST')   return handleScan(req, res);
  if (url === '/api/scan-one'        && req.method === 'POST')   return handleScanOne(req, res);
  if (url === '/api/stop'            && req.method === 'POST')   return handleStop(res);
  if (url === '/api/override'        && req.method === 'POST')   return handleOverride(req, res);
  if (url === '/api/override'        && req.method === 'DELETE') return handleOverrideDelete(req, res);
  if (url === '/api/log'             && req.method === 'GET')    return handleLog(res);
  if (url === '/api/status'          && req.method === 'GET')    return handleStatus(res);

  handleStatic(req, res);
}).listen(PORT, () => {
  console.log(`[SERVER] Hi-Res Scanner na porcie ${PORT}`);
  console.log(`[SERVER] DATA_PATH=${DATA_PATH} | MUSIC_PATH=${MUSIC_PATH}`);
});
