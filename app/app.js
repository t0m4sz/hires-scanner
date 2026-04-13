'use strict';

// ── STATUS CONFIG ─────────────────────────────────────────────────────────────
const SC = {
  'NATIVE HIRES':        { cls:'NH',  order:0,  color:'#4caf82' },
  'NATIVE HIRES?':       { cls:'NHQ', order:1,  color:'#a8c070' },
  'UPSAMPLED':           { cls:'UP',  order:2,  color:'#e05050' },
  'UPSAMPLED?':          { cls:'UPQ', order:3,  color:'#d08040' },
  'HI-RES 44/48':        { cls:'H4',  order:4,  color:'#6090d0' },
  'NATIVE HIRES (meta)': { cls:'ME',  order:5,  color:'#507090' },
  'HI-RES 44/48 (meta)': { cls:'ME', order:6,  color:'#507090' },
  'CD QUALITY':          { cls:'CD',  order:7,  color:'#888'    },
  'CD QUALITY (meta)':   { cls:'ME',  order:8,  color:'#507090' },
  'MIXED':               { cls:'MX',  order:9,  color:'#b060c0' },
  'UNKNOWN':             { cls:'UN',  order:10, color:'#aa8822' },
  'ERROR':               { cls:'ER',  order:11, color:'#e05050' },
};

const ALL_STATUSES = Object.keys(SC).filter(s => !s.includes('meta') && s !== 'MIXED' && s !== 'ERROR');

// ── STATE ─────────────────────────────────────────────────────────────────────
let allResults     = [];
let meta           = {};
let overrides      = {};
let activeFilter   = '';
let fArtist        = '';
let fAlbum         = '';
let sortCol        = 'artist';
let sortDir        = 1;
let scanMode       = 'incremental';
let pollTimer      = null;
let hasSeenRunning = false;
let collapsed      = new Set();

// ── CLIPBOARD ─────────────────────────────────────────────────────────────────
function copyPath(btn, text) {
  const ok = () => {
    btn.textContent = '✓ Skopiowano';
    btn.classList.add('copied');
    setTimeout(() => { btn.textContent = '⧉ Kopiuj'; btn.classList.remove('copied'); }, 2000);
  };
  const fail = () => { btn.textContent = '✗ Błąd'; setTimeout(() => { btn.textContent = '⧉ Kopiuj'; }, 2000); };
  if (navigator.clipboard && window.isSecureContext) {
    navigator.clipboard.writeText(text).then(ok).catch(() => fallbackCopy(text, ok, fail));
  } else fallbackCopy(text, ok, fail);
}

function fallbackCopy(text, onOk, onFail) {
  const el = document.createElement('textarea');
  el.value = text; el.style.cssText = 'position:fixed;top:-9999px;left:-9999px;opacity:0';
  document.body.appendChild(el); el.focus(); el.select();
  try { document.execCommand('copy') ? onOk() : onFail(); } catch { onFail(); }
  document.body.removeChild(el);
}

function escH(s) {
  return String(s||'').replace(/&/g,'&amp;').replace(/</g,'&lt;').replace(/>/g,'&gt;').replace(/"/g,'&quot;');
}

// ── API ───────────────────────────────────────────────────────────────────────
async function loadResults() {
  try {
    const d = await fetch('/api/results').then(r => r.json());
    allResults = d.results || [];
    meta       = d.meta    || {};
    overrides  = d.overrides || {};
    renderAll();
  } catch(e) { console.error(e); }
}

async function checkProgress() {
  try {
    const p = await fetch('/api/progress').then(r => r.json());
    updateProgress(p);
    if (p.running) hasSeenRunning = true;
    if (hasSeenRunning && !p.running) {
      clearInterval(pollTimer); pollTimer = null;
      hasSeenRunning = false;
      setBtnIdle();
      await loadResults();
    }
  } catch {}
}

// ── PROGRESS ──────────────────────────────────────────────────────────────────
function updateProgress(p) {
  const wrap = document.getElementById('progressWrap');
  if (!p.running && !hasSeenRunning) { wrap.classList.remove('visible'); return; }
  wrap.classList.add('visible');
  const pct = p.total > 0 ? Math.round((p.done / p.total) * 100) : 0;
  document.getElementById('progressFill').style.width = pct + '%';
  document.getElementById('progressLabel').textContent = p.running
    ? `Skanowanie... ${p.done||0}/${p.total||'?'} albumów (${pct}%)`
    : `Zakończono: ${p.done} albumów, błędy: ${p.errors}`;
  document.getElementById('progressCur').textContent = p.current ? `⟶ ${p.current}` : '';
  if (!p.running) setTimeout(() => wrap.classList.remove('visible'), 4000);
}

// ── STATS ─────────────────────────────────────────────────────────────────────
function renderStats() {
  const counts = {};
  allResults.forEach(r => { counts[r.status] = (counts[r.status]||0) + 1; });
  const total      = allResults.length;
  const totalFiles = allResults.reduce((s,r) => s+(r.fileCount||0), 0);

  const grid = document.getElementById('statsGrid');
  grid.innerHTML = '';
  grid.appendChild(makeStatCard('', '#d4a843', total, totalFiles, 'albumy / pliki'));
  Object.entries(SC)
    .filter(([s]) => counts[s])
    .sort(([,a],[,b]) => a.order-b.order)
    .forEach(([status, cfg]) => grid.appendChild(makeStatCard(status, cfg.color, counts[status], null, status)));

  document.getElementById('lastScan').textContent     = meta.lastScan ? new Date(meta.lastScan).toLocaleString('pl-PL') : '–';
  document.getElementById('scanDuration').textContent = meta.duration    || '–';
  document.getElementById('totalAlbums').textContent  = meta.totalAlbums ?? '–';
  document.getElementById('totalFiles').textContent   = meta.totalFiles  ?? '–';
  const err = meta.errors ?? 0;
  document.getElementById('totalErrors').textContent = err;
  document.getElementById('logLink').innerHTML = err > 0 ? `<a href="/api/log" target="_blank">[podgląd logu]</a>` : '';
}

function makeStatCard(status, color, mainNum, subNum, label) {
  const d = document.createElement('div');
  d.className = 'stat-card' + (activeFilter === status ? ' active' : '');
  d.style.setProperty('--card-color', color);
  let nums = `<div class="stat-main">${mainNum}</div>`;
  if (subNum !== null && subNum !== undefined) nums += `<div class="stat-sub">${subNum}</div>`;
  d.innerHTML = `<div class="stat-numbers">${nums}</div><div class="stat-label">${escH(label||'wszystkie')}</div>`;
  d.addEventListener('click', () => { activeFilter = (activeFilter === status) ? '' : status; renderAll(); });
  return d;
}

// ── BADGE ─────────────────────────────────────────────────────────────────────
function badge(status, tooltip, isManual) {
  const cfg = SC[status] || { cls:'UN' };
  const manualIcon = isManual ? ' <span class="manual-icon" title="Status ustawiony ręcznie">✎</span>' : '';
  const b = `<span class="badge ${cfg.cls}">${escH(status)}${manualIcon}</span>`;
  if (status === 'MIXED' && tooltip) {
    const lines = tooltip.split('|').map(escH).join('<br>');
    return `<div class="tip-wrap">${b}<div class="tip">${lines}</div></div>`;
  }
  return b;
}

// ── OVERRIDE MENU ─────────────────────────────────────────────────────────────
let openMenuPath = null;

function closeAllMenus() {
  document.querySelectorAll('.status-menu').forEach(m => m.remove());
  openMenuPath = null;
}

function openStatusMenu(btn, albumPath, currentStatus) {
  if (openMenuPath === albumPath) { closeAllMenus(); return; }
  closeAllMenus();
  openMenuPath = albumPath;

  const menu = document.createElement('div');
  menu.className = 'status-menu';

  // Reset option
  const resetBtn = document.createElement('div');
  resetBtn.className = 'status-menu-item status-menu-reset';
  resetBtn.textContent = '↺ Resetuj do wyniku skanu';
  resetBtn.addEventListener('click', async () => {
    closeAllMenus();
    await fetch('/api/override', { method:'DELETE', headers:{'Content-Type':'application/json'}, body:JSON.stringify({path:albumPath}) });
    await loadResults();
  });
  menu.appendChild(resetBtn);

  const sep = document.createElement('div');
  sep.className = 'status-menu-sep';
  menu.appendChild(sep);

  ALL_STATUSES.forEach(s => {
    const item = document.createElement('div');
    item.className = 'status-menu-item' + (s === currentStatus ? ' active' : '');
    const cfg = SC[s] || {cls:'UN'};
    item.innerHTML = `<span class="badge ${cfg.cls}" style="font-size:10px;padding:2px 5px">${escH(s)}</span>`;
    item.addEventListener('click', async () => {
      closeAllMenus();
      await fetch('/api/override', {
        method:'POST', headers:{'Content-Type':'application/json'},
        body:JSON.stringify({ path:albumPath, status:s, confidence:'Recznie ustawiony' }),
      });
      await loadResults();
    });
    menu.appendChild(item);
  });

  const rect = btn.getBoundingClientRect();
  menu.style.top  = (rect.bottom + window.scrollY + 4) + 'px';
  menu.style.left = (rect.left + window.scrollX) + 'px';
  document.body.appendChild(menu);
}

document.addEventListener('click', e => {
  if (!e.target.closest('.status-menu') && !e.target.closest('.edit-btn')) closeAllMenus();
});

// ── SINGLE RESCAN ─────────────────────────────────────────────────────────────
async function rescanOne(btn, albumPath) {
  if (btn.disabled) return;
  btn.disabled = true; btn.textContent = '⟳';
  try {
    await fetch('/api/scan-one', {
      method:'POST', headers:{'Content-Type':'application/json'},
      body:JSON.stringify({ path: albumPath }),
    });
    pollTimer = setInterval(async () => {
      const p = await fetch('/api/progress').then(r=>r.json()).catch(()=>({running:false}));
      if (p.singleDir && !p.running) {
        clearInterval(pollTimer); pollTimer = null;
        btn.disabled = false; btn.textContent = '⟳';
        await loadResults();
      }
    }, 1000);
  } catch(e) {
    btn.disabled = false; btn.textContent = '⟳';
    alert('Błąd: ' + e.message);
  }
}

// ── TABLE ─────────────────────────────────────────────────────────────────────
function sortArrow(col) { return sortCol===col ? (sortDir>0?' ↑':' ↓') : ''; }

function getFiltered() {
  return allResults.filter(r => {
    if (activeFilter && r.status !== activeFilter) return false;
    if (fArtist && !(r.artist||'').toLowerCase().includes(fArtist.toLowerCase())) return false;
    if (fAlbum  && !(r.album ||'').toLowerCase().includes(fAlbum.toLowerCase()))  return false;
    return true;
  });
}

function renderAll() { renderStats(); renderTable(); }

function renderTable() {
  const wrap    = document.getElementById('tableWrap');
  const emptyEl = document.getElementById('emptyState');
  const filtered = getFiltered();

  document.getElementById('rc').textContent = filtered.length !== allResults.length
    ? `${filtered.length} z ${allResults.length} albumów` : `${allResults.length} albumów`;

  if (filtered.length === 0) { wrap.innerHTML = ''; wrap.appendChild(emptyEl); return; }

  const sorted = [...filtered].sort((a,b) =>
    (a[sortCol]||'').toString().localeCompare((b[sortCol]||'').toString()) * sortDir);

  const groups = {};
  sorted.forEach(r => { (groups[r.status] = groups[r.status]||[]).push(r); });
  const sortedGroups = Object.keys(groups).sort((a,b) => ((SC[a]?.order??99)-(SC[b]?.order??99)));

  const table = document.createElement('table');
  const thead = document.createElement('thead');
  thead.innerHTML = `<tr>
    <th data-col="artist" class="${sortCol==='artist'?'sorted':''}">Wykonawca${sortArrow('artist')}</th>
    <th data-col="album"  class="${sortCol==='album' ?'sorted':''}">Album${sortArrow('album')}</th>
    <th>Status</th>
    <th style="text-align:center">Pliki</th>
    <th>Akcje</th>
  </tr>`;
  thead.querySelectorAll('th[data-col]').forEach(th => {
    th.addEventListener('click', () => {
      (sortCol===th.dataset.col) ? (sortDir*=-1) : (sortCol=th.dataset.col, sortDir=1);
      renderTable();
    });
  });
  table.appendChild(thead);

  const tbody = document.createElement('tbody');

  sortedGroups.forEach(gs => {
    const items = groups[gs];
    const cfg   = SC[gs] || {cls:'UN', color:'#888'};
    const isCol = collapsed.has(gs);

    const gtr = document.createElement('tr');
    gtr.className = 'group-hdr';
    gtr.innerHTML = `<td colspan="5">
      <div class="group-inner">
        <span class="badge ${cfg.cls}">${escH(gs)}</span>
        <span class="group-cnt">${items.length} ${items.length===1?'album':'albumów'}</span>
        <span class="group-arr ${isCol?'':'open'}">▶</span>
      </div>
    </td>`;
    gtr.querySelector('td').addEventListener('click', () => {
      collapsed.has(gs) ? collapsed.delete(gs) : collapsed.add(gs);
      renderTable();
    });
    tbody.appendChild(gtr);

    if (!isCol) {
      items.forEach(r => {
        const tr       = document.createElement('tr');
        const winPath  = r.winPath || r.path || '';
        const isManual = !!r.manual;

        tr.innerHTML = `
          <td class="td-a">${escH(r.artist||'–')}</td>
          <td class="td-b">${escH(r.album ||'–')}${r.scanId && meta.lastScanId && r.scanId === meta.lastScanId && meta.mode === 'incremental' ? ' <span class="badge-new">NEW</span>' : ''}</td>
          <td>${badge(r.status, r.tooltip, isManual)}</td>
          <td class="td-f">${r.fileCount||'–'}</td>
          <td class="td-actions"></td>`;

        const actions = tr.querySelector('.td-actions');

        // Copy button
        const copyWrap = document.createElement('div');
        copyWrap.className = 'copy-wrap';
        const copyBtn = document.createElement('button');
        copyBtn.className = 'copy-btn'; copyBtn.textContent = '⧉ Kopiuj';
        const copyTip = document.createElement('div');
        copyTip.className = 'copy-tip'; copyTip.textContent = winPath;
        copyBtn.addEventListener('click', () => copyPath(copyBtn, winPath));
        copyWrap.appendChild(copyBtn); copyWrap.appendChild(copyTip);
        actions.appendChild(copyWrap);

        // Edit status button
        const editBtn = document.createElement('button');
        editBtn.className = 'edit-btn'; editBtn.title = 'Zmień status ręcznie'; editBtn.textContent = '✎';
        editBtn.addEventListener('click', e => { e.stopPropagation(); openStatusMenu(editBtn, r.path, r.status); });
        actions.appendChild(editBtn);

        // Rescan button
        const rescanBtn = document.createElement('button');
        rescanBtn.className = 'rescan-btn'; rescanBtn.title = 'Przeskanuj ten album ponownie'; rescanBtn.textContent = '⟳';
        rescanBtn.addEventListener('click', () => rescanOne(rescanBtn, r.path));
        actions.appendChild(rescanBtn);

        tbody.appendChild(tr);
      });
    }
  });

  table.appendChild(tbody);
  wrap.innerHTML = '';
  wrap.appendChild(table);
}

// ── COLLAPSE ALL / EXPAND ALL ─────────────────────────────────────────────────
document.getElementById('btnCollapseAll').addEventListener('click', () => {
  const filtered = getFiltered();
  const groups = {};
  filtered.forEach(r => { groups[r.status] = true; });
  Object.keys(groups).forEach(g => collapsed.add(g));
  renderTable();
});

document.getElementById('btnExpandAll').addEventListener('click', () => {
  collapsed.clear();
  renderTable();
});

// ── MODAL ─────────────────────────────────────────────────────────────────────
document.getElementById('btnScan').addEventListener('click', () => document.getElementById('modalOv').classList.add('visible'));
document.getElementById('btnCancel').addEventListener('click', () => document.getElementById('modalOv').classList.remove('visible'));
document.getElementById('modalOv').addEventListener('click', e => {
  if (e.target === document.getElementById('modalOv')) document.getElementById('modalOv').classList.remove('visible');
});
['optInc','optFull'].forEach(id => {
  document.getElementById(id).addEventListener('click', () => {
    document.getElementById('optInc').classList.remove('sel');
    document.getElementById('optFull').classList.remove('sel');
    document.getElementById(id).classList.add('sel');
    scanMode = (id==='optFull') ? 'full' : 'incremental';
  });
});

function setBtnIdle() {
  const b = document.getElementById('btnScan');
  b.disabled = false; b.textContent = '⬡ SKANUJ PLIKI';
  document.getElementById('btnStop').style.display = 'none';
}
function setBtnScanning() {
  const b = document.getElementById('btnScan');
  b.disabled = true; b.textContent = '⟳ SKANOWANIE...';
  document.getElementById('btnStop').style.display = 'inline-block';
}
async function stopScan() {
  try { await fetch('/api/stop', { method:'POST' }); document.getElementById('btnStop').style.display = 'none'; }
  catch(e) { console.error(e); }
}

document.getElementById('btnStart').addEventListener('click', async () => {
  document.getElementById('modalOv').classList.remove('visible');
  setBtnScanning(); hasSeenRunning = false;
  document.getElementById('progressWrap').classList.add('visible');
  try {
    await fetch('/api/scan', { method:'POST', headers:{'Content-Type':'application/json'}, body:JSON.stringify({ mode:scanMode }) });
    pollTimer = setInterval(checkProgress, 1000);
  } catch(e) { alert('Błąd: ' + e.message); setBtnIdle(); }
});

// ── FILTERS ───────────────────────────────────────────────────────────────────
document.getElementById('fArtist').addEventListener('input', e => { fArtist = e.target.value; renderTable(); });
document.getElementById('fAlbum').addEventListener('input',  e => { fAlbum  = e.target.value; renderTable(); });
document.getElementById('btnClear').addEventListener('click', () => {
  fArtist=''; fAlbum=''; activeFilter='';
  document.getElementById('fArtist').value='';
  document.getElementById('fAlbum').value='';
  renderAll();
});

// ── INIT ──────────────────────────────────────────────────────────────────────
async function init() {
  await loadResults();
  try {
    const p = await fetch('/api/progress').then(r=>r.json());
    if (p.running) {
      setBtnScanning(); hasSeenRunning = true;
      document.getElementById('progressWrap').classList.add('visible');
      pollTimer = setInterval(checkProgress, 1000);
    }
  } catch {}
}

init();
