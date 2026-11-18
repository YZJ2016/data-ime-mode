// Owns the native port and the "what did we change, and to what" bookkeeping.
// The host is stateless apart from its own crash-safety restore.

const HOST_NAME = 'io.github.fukunagajiro.data_ime_mode';
const KEEPALIVE_MS = 20000;

let port = null;
let seq = 0;
const waiters = new Map();

// ポートが切れた理由。ホスト未登録なら connectNative は同期的に throw せず、
// "Specified native messaging host not found." で切断する。popup の診断は
// この文字列がないと「登録されていない」と「起動したが応答しない」を区別できない。
let lastDisconnect = null;

// The window we touched and the IME state it had before we touched it.
let saved = null; // { hwnd, pid, open, conv, windowId }
let owner = null;
let field = null;
const held = new Map();
const browser = typeof navigator === 'undefined' ? undefined :
  (/\bEdg\//.test(navigator.userAgent) ? 'msedge' : 'chrome');

// Requests are serialized: focus events arrive faster than the round trip,
// and out-of-order set/restore would leave the IME in the wrong state.
let queue = Promise.resolve();

function connect() {
  if (port) return port;

  port = chrome.runtime.connectNative(HOST_NAME);

  port.onMessage.addListener((msg) => {
    const resolve = waiters.get(msg.id);
    if (resolve) {
      waiters.delete(msg.id);
      resolve(msg);
    }
  });

  port.onDisconnect.addListener(() => {
    const err = chrome.runtime.lastError;
    lastDisconnect = err ? err.message : null;
    if (err) console.warn('[data-ime-mode] native host disconnected:', err.message);
    port = null;
    saved = null;
    owner = null;
    field = null;
    for (const resolve of waiters.values()) resolve({ ok: false, error: 'disconnected' });
    waiters.clear();
  });

  return port;
}

function call(req) {
  return new Promise((resolve) => {
    let p;
    try {
      p = connect();
    } catch (e) {
      resolve({ ok: false, error: String(e) });
      return;
    }
    const id = ++seq;
    waiters.set(id, resolve);
    setTimeout(() => {
      if (waiters.delete(id)) resolve({ ok: false, error: 'timeout' });
    }, 3000);
    try {
      p.postMessage({ ...req, id });
    } catch (e) {
      waiters.delete(id);
      resolve({ ok: false, error: String(e) });
    }
  });
}

async function rememberField() {
  if (!field || !saved) return;
  const r = await call({ cmd: 'get', hwnd: saved.hwnd, pid: saved.pid, browser });
  if (!r.ok) return;
  // Bound the cache across SPA rerenders and closed documents.
  held.delete(field);
  held.set(field, { open: r.open, convRaw: r.conv });
  if (held.size > 512) held.delete(held.keys().next().value);
}

async function release() {
  if (!saved) return { ok: true };
  const s = saved;
  const r = await call({ cmd: 'set', open: s.open, convRaw: s.conv,
    hwnd: s.hwnd, pid: s.pid, browser, restore: true });
  if (r.ok || r.error === 'target window changed') saved = null;
  return r;
}

async function changeFocus(msg, sender) {
  const { windowId } = sender.tab || {};
  const source = JSON.stringify([sender.tab?.id, sender.frameId, sender.documentId]);
  if (!msg.spec && source !== owner) return { ok: true };

  if (msg.spec && sender.tab && chrome.tabs && chrome.windows) {
    const [tab, win] = await Promise.all([
      chrome.tabs.get(sender.tab.id), chrome.windows.get(windowId),
    ]);
    if (!tab.active || !win.focused || tab.windowId !== windowId) {
      return { ok: false, error: 'browser tab lost focus' };
    }
  }

  const nextField = msg.field != null ? JSON.stringify([source, msg.field]) : null;
  const previousField = field;
  if (field !== nextField || source !== owner) await rememberField();
  if (!msg.spec) {
    field = null;
    if (msg.retain && previousField && saved) return { ok: true };
    const r = await release();
    if (r.ok) owner = null;
    return r;
  }

  if (saved && saved.windowId !== windowId) {
    const r = await release();
    if (!r.ok && saved) return r;
  }

  const spec = held.get(nextField) || msg.spec;
  const r = await call({ cmd: 'set', ...spec, hwnd: saved?.hwnd || 0,
    pid: saved?.pid, browser, ...(held.has(nextField) ? { held: true } : {}) });
  // The host can change one setting successfully before another fails.
  // Retain the original state so blur can still undo a partial write.
  if (!saved && r.hwnd && r.previous != null) {
    saved = { hwnd: r.hwnd, pid: r.pid, open: r.previous, conv: r.previousConv, windowId };
  }
  if (saved) {
    owner = source;
    field = nextField;
  }
  return r;
}

function enqueue(fn) {
  queue = queue.then(fn).catch((e) => console.warn('[data-ime-mode]', e));
  return queue;
}

chrome.runtime.onMessage.addListener((msg, _sender, sendResponse) => {
  if (!msg || msg.type !== 'ime') return;

  // popup からの疎通確認。ホストへ実際に ping を通し、結果を非同期に返す。
  // Return true to keep the response channel open while the host replies.
  if (msg.probe) {
    enqueue(() =>
      call({ cmd: 'ping' }).then((r) => {
        if (r && r.ok) sendResponse({ ok: true });
        else sendResponse({ ok: false, error: (r && r.error) || 'unknown', detail: lastDisconnect });
      })
    );
    return true;
  }

  // prewarm は spec の判定より前に処理する。spec を持たないメッセージは
  // release として扱われるので、後ろに置くとページを開くたびに解放が走る。
  // ping はホスト側でウィンドウ解決も IME 操作もせず即返るので、ポートを
  // 開けてプロセスを起こすだけで済む。
  if (msg.prewarm) {
    enqueue(() => call({ cmd: 'ping' }));
    sendResponse({ ok: true });
    return;
  }

  enqueue(async () => {
    let result;
    try {
      result = await changeFocus(msg, _sender);
    } catch (error) {
      result = { ok: false, error: String(error) };
    }
    if (!result.ok) console.warn('[data-ime-mode]', result.error);
    sendResponse(result);
  });
  return true;
});

// An open native port keeps the service worker alive, but a periodic message
// makes that explicit rather than relying on eviction heuristics.
setInterval(() => {
  if (port) call({ cmd: 'ping' });
}, KEEPALIVE_MS);

// Edge の起動時点で温める。属性付きページを開いた時では、autofocus された
// 対象欄には間に合わない（フォーカスと prewarm が同じ瞬間に起きる）。
chrome.runtime.onStartup.addListener(() => enqueue(() => call({ cmd: 'ping' })));
