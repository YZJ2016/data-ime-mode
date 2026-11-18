// Watches focus movement and reports the desired IME state of the focused field.
// The attribute is only a marker; all actual IME manipulation happens in the host.

const ATTR = 'data-ime-mode';

// open: IME 開閉状態 / conv: 変換モード (null = 変えない)
const MODES = {
  'inactive':      { open: 0, conv: null },
  'active':        { open: 1, conv: null },
  'hiragana':      { open: 1, conv: 'hiragana' },
  'katakana':      { open: 1, conv: 'full-katakana' },
  'full-katakana': { open: 1, conv: 'full-katakana' },
  'full-alphanumeric': { open: 1, conv: 'full-alphanumeric' },
  'half-alphanumeric': { open: 1, conv: 'half-alphanumeric' },
  'half-katakana': { open: 1, conv: 'half-katakana' },
};

// Coalescing window for focusout -> focusin. Without it, moving between two
// controlled fields would restore and re-apply, causing a visible flicker.
const RELEASE_DELAY_MS = 40;

// null は「解放済み」を意味するので、送信できたか分からない状態はこれで表す。
// null ともどのモード名とも一致しないため、次が適用でも復帰でも必ず送り直される。
// 失敗を null に潰すと、離脱時の apply(null) が重複排除で消えて IME が
// 他アプリまで汚染されたまま取り残される。
const UNKNOWN = Symbol('unknown');

// ホストの PowerShell 起動は実測 1.2 秒かかる（内訳: powershell の起動 650ms と
// Add-Type による C# の実行時コンパイル 350ms）。フォーカスしてから払うと体感の
// 遅れになるので、対象欄を持つ文書を開いた時点で温めておく。ポートを持つのは
// サービスワーカーなので、1 度温めれば全タブで共有される。
let prewarmSent = false;

function prewarm() {
  if (prewarmSent) return;
  // 属性の存在だけを見る。値が既知のモードかは modeOf() の仕事で、判定を
  // 2 か所に持つと食い違って壊れる。属性を使っていないページでは 1 通も
  // 送らないので、PowerShell は起動しない。
  if (!document.querySelector(`[${ATTR}]`)) return;
  prewarmSent = true;
  try {
    // 適用ではないので currentMode には触らず、失敗も捨てる。forget() を
    // 呼ぶと重複排除の状態が汚れる。温め損なっても、次の適用が起動コストを
    // 払うだけで動作は正しい。
    const sent = chrome.runtime.sendMessage({ type: 'ime', prewarm: true });
    if (sent && typeof sent.catch === 'function') sent.catch(() => {});
  } catch {
    // 拡張機能の再読み込み中。次の適用でまた起動が試みられる。
  }
}

let currentMode = null;
let currentField = null;
let retained = false;
let request = 0;
let nextField = 0;
const heldFields = new WeakMap();

function holdId(el) {
  if (el?.getAttribute?.('data-ime-hold') !== 'true') return null;
  if (!heldFields.has(el)) heldFields.set(el, ++nextField);
  return heldFields.get(el);
}
let releaseTimer = null;

function modeOf(el) {
  if (!el || typeof el.getAttribute !== 'function') return null;
  const raw = el.getAttribute(ATTR);
  if (raw === null) return null;
  const v = raw.trim().toLowerCase();
  return Object.prototype.hasOwnProperty.call(MODES, v) ? v : null;
}

// The send did not land, so we must not keep claiming the mode is applied -
// apply()'s dedupe would swallow every retry. Only clear if nothing newer has
// been applied in the meantime.
function apply(mode, field = null, withinDocument = false) {
  if (mode === currentMode && field === currentField &&
      !(mode === null && retained && !withinDocument)) return;
  retained = withinDocument && mode === null && (currentField !== null || retained);
  currentMode = mode;
  currentField = field;
  const id = ++request;
  const forget = () => {
    if (request === id) currentMode = UNKNOWN;
  };
  try {
    const message = { type: 'ime', mode, spec: mode ? MODES[mode] : null };
    if (field !== null) message.field = field;
    if (withinDocument && mode === null) message.retain = true;
    const sent = chrome.runtime.sendMessage(message);
    if (sent && typeof sent.then === 'function') {
      sent.then(result => { if (result?.ok === false) forget(); }, forget);
    }
  } catch {
    forget();
  }
}

function cancelRelease() {
  if (releaseTimer !== null) {
    clearTimeout(releaseTimer);
    releaseTimer = null;
  }
}

document.addEventListener('focusin', (e) => {
  cancelRelease();
  if (!document.hasFocus()) return;
  const mode = modeOf(e.target);
  apply(mode, mode ? holdId(e.target) : null, true);
}, true);

document.addEventListener('focusout', () => {
  cancelRelease();
  releaseTimer = setTimeout(() => {
    releaseTimer = null;
    apply(null, null, document.hasFocus());
  }, RELEASE_DELAY_MS);
}, true);

// Edge 自体がフォアグラウンドを失った / タブが隠れた場合は必ず元に戻す。
// これを怠ると他アプリを操作中に IME が変更されたまま取り残される。
function releaseNow() {
  cancelRelease();
  apply(null);
}

// ...and re-apply on the way back, since the field is still focused but the
// mode was dropped on the way out. Symmetric with releaseNow: blur restored the
// pre-focus state, so this is not stomping a choice the user made in the field.
//
// hasFocus() guards against re-applying while Edge is not the foreground app -
// the host resolves hwnd 0 to the foreground window and would touch someone else.
function reapplyNow() {
  if (!document.hasFocus()) return;
  cancelRelease();
  const el = document.activeElement;
  const mode = modeOf(el);
  apply(mode, mode ? holdId(el) : null, true);
}

window.addEventListener('blur', releaseNow);
window.addEventListener('focus', reapplyNow);
window.addEventListener('pagehide', releaseNow);
document.addEventListener('visibilitychange', () => {
  if (document.visibilityState === 'hidden') releaseNow();
  else reapplyNow();
});

// content script は document_start で走るので、この時点では DOM がまだ無い。
// 他の実行タイミングで読み込まれても壊れないよう、両方に備える。
if (document.readyState === 'loading') {
  document.addEventListener('DOMContentLoaded', prewarm, { once: true });
} else {
  prewarm();
}
