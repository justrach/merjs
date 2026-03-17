// synth.zig — Wavetable synthesizer demo page.
// Full dark-theme standalone document (bypasses layout wrapper).
// AudioWorklet + WASM: the entire audio engine is Zig compiled to wasm32.

const mer = @import("mer");

pub const meta: mer.Meta = .{
    .title = "merjs synth",
    .description = "Wavetable synthesizer powered by Zig compiled to WASM. Runs entirely in your browser.",
};

pub fn render(req: mer.Request) mer.Response {
    _ = req;
    return mer.html(page);
}

const page = head ++ body ++ script ++ "</body></html>";

const head =
    \\<!DOCTYPE html>
    \\<html lang="en">
    \\<head>
    \\  <meta charset="UTF-8">
    \\  <meta name="viewport" content="width=device-width, initial-scale=1.0">
    \\  <title>merjs synth — wavetable synthesizer</title>
    \\  <link rel="preconnect" href="https://fonts.googleapis.com">
    \\  <link rel="preconnect" href="https://fonts.gstatic.com" crossorigin>
    \\  <link href="https://fonts.googleapis.com/css2?family=JetBrains+Mono:wght@400;500;600&display=swap" rel="stylesheet">
    \\  <style>
    \\    *, *::before, *::after { box-sizing: border-box; margin: 0; padding: 0; }
    \\    :root {
    \\      --bg:      #0b0b0f;
    \\      --surf:    #131318;
    \\      --surf2:   #1a1a22;
    \\      --border:  #252530;
    \\      --border2: #32323f;
    \\      --text:    #d0d0dc;
    \\      --muted:   #555568;
    \\      --green:   #00d084;
    \\      --cyan:    #00b8d9;
    \\      --purple:  #9b5de5;
    \\      --orange:  #f4a03a;
    \\      --red:     #e8251f;
    \\    }
    \\    body {
    \\      background: var(--bg);
    \\      color: var(--text);
    \\      font-family: 'JetBrains Mono', 'Fira Mono', monospace;
    \\      min-height: 100vh;
    \\      overflow-x: hidden;
    \\    }
    \\    a { color: var(--muted); text-decoration: none; font-size: 12px; }
    \\    a:hover { color: var(--text); }
    \\
    \\    /* ── Shell ── */
    \\    /* ── Shell ── */
    \\    .shell {
    \\      max-width: 820px;
    \\      margin: 0 auto;
    \\      padding: 24px 24px 64px;
    \\    }
    \\    /* ── Header ── */
    \\    .hdr {
    \\      display: flex;
    \\      align-items: center;
    \\      justify-content: space-between;
    \\      margin-bottom: 18px;
    \\    }
    \\    .wordmark {
    \\      font-size: 18px;
    \\      font-weight: 600;
    \\      letter-spacing: -0.02em;
    \\      color: #fff;
    \\    }
    \\    .wordmark em { color: var(--green); font-style: normal; }
    \\    .badges { display: flex; gap: 8px; }
    \\    .badge {
    \\      font-size: 10px;
    \\      font-weight: 500;
    \\      letter-spacing: 0.08em;
    \\      padding: 3px 8px;
    \\      border-radius: 3px;
    \\    }
    \\    .b-wasm {
    \\      background: var(--green);
    \\      color: #000;
    \\    }
    \\    .b-wasm.inactive { background: var(--surf2); color: var(--muted); border: 1px solid var(--border); }
    \\    .b-sr { background: var(--surf2); color: var(--muted); border: 1px solid var(--border); }
    \\
    \\    /* ── Oscilloscope ── */
    \\    #osc {
    \\      display: block;
    \\      width: 100%;
    \\      height: 150px;
    \\      background: var(--surf);
    \\      border: 1px solid var(--border);
    \\      border-radius: 6px;
    \\      margin-bottom: 16px;
    \\    }
    \\
    \\    /* ── Controls grid ── */
    \\    .ctrls {
    \\      display: grid;
    \\      grid-template-columns: 1fr 2fr 1fr;
    \\      gap: 12px;
    \\      margin-bottom: 16px;
    \\      align-items: start;
    \\    }
    \\    .panel {
    \\      background: var(--surf);
    \\      border: 1px solid var(--border);
    \\      border-radius: 6px;
    \\      padding: 14px;
    \\    }
    \\    .panel-lbl {
    \\      display: block;
    \\      font-size: 9px;
    \\      font-weight: 600;
    \\      letter-spacing: 0.14em;
    \\      text-transform: uppercase;
    \\      color: var(--muted);
    \\      margin-bottom: 12px;
    \\    }
    \\
    \\    /* Waveform buttons */
    \\    .wave-list { display: flex; flex-direction: column; gap: 5px; }
    \\    .wbtn {
    \\      background: transparent;
    \\      border: 1px solid var(--border);
    \\      color: var(--muted);
    \\      font-family: inherit;
    \\      font-size: 12px;
    \\      padding: 7px 10px;
    \\      border-radius: 4px;
    \\      cursor: pointer;
    \\      text-align: left;
    \\      transition: border-color 0.1s, color 0.1s, background 0.1s;
    \\    }
    \\    .wbtn:hover { border-color: var(--green); color: var(--text); }
    \\    .wbtn.on {
    \\      border-color: var(--green);
    \\      color: var(--green);
    \\      background: rgba(0, 208, 132, 0.06);
    \\    }
    \\
    \\    /* ADSR rows */
    \\    .env-row {
    \\      display: flex;
    \\      align-items: center;
    \\      gap: 8px;
    \\      margin-bottom: 8px;
    \\    }
    \\    .env-row:last-child { margin-bottom: 0; }
    \\    .env-key {
    \\      font-size: 11px;
    \\      font-weight: 600;
    \\      color: var(--muted);
    \\      width: 16px;
    \\      min-width: 16px;
    \\      flex-shrink: 0;
    \\    }
    \\    .env-val {
    \\      font-size: 11px;
    \\      color: var(--cyan);
    \\      width: 44px;
    \\      text-align: right;
    \\      flex-shrink: 0;
    \\    }
    \\
    \\    /* Timbre rows */
    \\    .tmb-row {
    \\      display: flex;
    \\      align-items: center;
    \\      gap: 8px;
    \\      margin-bottom: 8px;
    \\    }
    \\    .tmb-row:last-child { margin-bottom: 0; }
    \\    .tmb-key {
    \\      font-size: 10px;
    \\      color: var(--muted);
    \\      width: 30px;
    \\      flex-shrink: 0;
    \\    }
    \\    .tmb-val {
    \\      font-size: 11px;
    \\      color: var(--green);
    \\      width: 36px;
    \\      text-align: right;
    \\      flex-shrink: 0;
    \\    }
    \\
    \\    /* Sliders */
    \\    input[type=range] {
    \\      -webkit-appearance: none;
    \\      appearance: none;
    \\      flex: 1;
    \\      height: 2px;
    \\      background: var(--border2);
    \\      border-radius: 2px;
    \\      outline: none;
    \\      cursor: pointer;
    \\    }
    \\    input[type=range]::-webkit-slider-thumb {
    \\      -webkit-appearance: none;
    \\      width: 11px; height: 11px;
    \\      border-radius: 50%;
    \\      background: var(--cyan);
    \\      cursor: pointer;
    \\      box-shadow: 0 0 5px var(--cyan);
    \\    }
    \\    input[type=range]::-moz-range-thumb {
    \\      width: 11px; height: 11px;
    \\      border-radius: 50%;
    \\      background: var(--cyan);
    \\      cursor: pointer;
    \\      border: none;
    \\    }
    \\    .grn-thumb::-webkit-slider-thumb { background: var(--green); box-shadow: 0 0 5px var(--green); }
    \\    .grn-thumb::-moz-range-thumb     { background: var(--green); }
    \\
    \\    /* ── Piano ── */
    \\    .piano-wrap {
    \\      background: var(--surf);
    \\      border: 1px solid var(--border);
    \\      border-radius: 6px;
    \\      padding: 16px;
    \\      margin-bottom: 14px;
    \\      overflow-x: auto;
    \\    }
    \\    .piano {
    \\      position: relative;
    \\      height: 138px;
    \\      width: 700px;
    \\      margin: 0 auto;
    \\    }
    \\    .key {
    \\      position: absolute;
    \\      user-select: none;
    \\      cursor: pointer;
    \\      touch-action: none;
    \\    }
    \\    .kw {
    \\      width: 49px; height: 138px;
    \\      background: #e8e4dc;
    \\      border: 1px solid #aaa;
    \\      border-top: none;
    \\      border-radius: 0 0 5px 5px;
    \\      z-index: 1;
    \\      display: flex;
    \\      align-items: flex-end;
    \\      justify-content: center;
    \\      padding-bottom: 7px;
    \\      transition: background 0.06s;
    \\    }
    \\    .kw:hover { background: #d4f0e2; }
    \\    .kw.on    { background: var(--green); box-shadow: 0 0 14px rgba(0,208,132,0.5); }
    \\    .kb {
    \\      width: 29px; height: 88px;
    \\      background: #18181e;
    \\      border: 1px solid #000;
    \\      border-top: none;
    \\      border-radius: 0 0 4px 4px;
    \\      z-index: 2;
    \\      display: flex;
    \\      align-items: flex-end;
    \\      justify-content: center;
    \\      padding-bottom: 5px;
    \\      transition: background 0.06s;
    \\    }
    \\    .kb:hover { background: #1e2a24; }
    \\    .kb.on    { background: var(--green); box-shadow: 0 0 10px rgba(0,208,132,0.6); }
    \\    .khint {
    \\      font-size: 9px;
    \\      color: rgba(0,0,0,0.28);
    \\      font-family: inherit;
    \\      pointer-events: none;
    \\    }
    \\    .kb .khint { color: rgba(255,255,255,0.22); }
    \\    .kw.on .khint { color: rgba(0,0,0,0.5); }
    \\    .kb.on .khint { color: rgba(0,0,0,0.5); }
    \\
    \\    /* ── Key guide ── */
    \\    .kguide {
    \\      font-size: 11px;
    \\      color: var(--muted);
    \\      text-align: center;
    \\      letter-spacing: 0.02em;
    \\      margin-bottom: 24px;
    \\    }
    \\    .kguide strong { color: var(--border2); }
    \\
    \\    /* ── Start overlay ── */
    \\    #overlay {
    \\      position: fixed;
    \\      inset: 0;
    \\      background: rgba(11, 11, 15, 0.96);
    \\      display: flex;
    \\      flex-direction: column;
    \\      align-items: center;
    \\      justify-content: center;
    \\      z-index: 200;
    \\      cursor: pointer;
    \\    }
    \\    .ov-title {
    \\      font-size: 36px;
    \\      font-weight: 600;
    \\      color: #fff;
    \\      letter-spacing: -0.03em;
    \\      margin-bottom: 8px;
    \\    }
    \\    .ov-title em { color: var(--green); font-style: normal; }
    \\    .ov-sub {
    \\      font-size: 12px;
    \\      color: var(--muted);
    \\      margin-bottom: 36px;
    \\      text-align: center;
    \\      line-height: 1.7;
    \\    }
    \\    .ov-btn {
    \\      padding: 14px 36px;
    \\      background: var(--green);
    \\      color: #000;
    \\      border: none;
    \\      border-radius: 4px;
    \\      font-family: inherit;
    \\      font-size: 13px;
    \\      font-weight: 600;
    \\      letter-spacing: 0.06em;
    \\      cursor: pointer;
    \\      box-shadow: 0 0 28px rgba(0, 208, 132, 0.35);
    \\      transition: box-shadow 0.2s;
    \\    }
    \\    .ov-btn:hover { box-shadow: 0 0 40px rgba(0, 208, 132, 0.55); }
    \\    .ov-note {
    \\      font-size: 11px;
    \\      color: var(--muted);
    \\      margin-top: 20px;
    \\    }
    \\    .ov-note strong { color: var(--green); }
    \\
    \\    /* ── Footer ── */
    \\    .foot {
    \\      font-size: 11px;
    \\      color: var(--muted);
    \\      text-align: center;
    \\      padding-top: 16px;
    \\      border-top: 1px solid var(--border);
    \\    }
    \\
    \\
    \\    @media (max-width: 640px) {
    \\      .ctrls { grid-template-columns: 1fr 1fr; }
    \\      .ctrls .panel:nth-child(2) { grid-column: 1 / -1; order: -1; }
    \\    }
    \\  </style>
    \\</head>
;

const body =
    \\<body>
    \\
    \\<!-- Start overlay -->
    \\<div id="overlay">
    \\  <div class="ov-title">merjs <em>synth</em></div>
    \\  <div class="ov-sub">
    \\    wavetable synthesizer &middot; zig &rarr; wasm<br>
    \\    the entire audio engine is compiled from zig source
    \\  </div>
    \\  <button class="ov-btn" id="startbtn">&#9654; CLICK TO START</button>
    \\  <div class="ov-note">runs in <strong>AudioWorklet + WASM</strong> &mdash; zero JS handles audio</div>
    \\</div>
    \\
    \\<div class="shell">
    \\
    \\  <!-- Header -->
    \\  <div class="hdr">
    \\    <div class="wordmark"><a href="/" style="color:#fff;font-size:inherit;font-weight:inherit">merjs</a> <em>synth</em></div>
    \\    <div class="badges">
    \\      <span class="badge b-wasm inactive" id="wasm-badge">&#9711; WASM</span>
    \\      <span class="badge b-sr" id="sr-badge">-- Hz</span>
    \\    </div>
    \\  </div>
    \\
    \\  <!-- Oscilloscope -->
    \\  <canvas id="osc"></canvas>
    \\
    \\  <!-- Controls -->
    \\  <div class="ctrls">
    \\
    \\    <!-- Waveform -->
    \\    <div class="panel">
    \\      <span class="panel-lbl">waveform</span>
    \\      <div class="wave-list">
    \\        <button class="wbtn on" data-wave="0">&#8767; sine</button>
    \\        <button class="wbtn"    data-wave="1">&#8911; square</button>
    \\        <button class="wbtn"    data-wave="2">&#8725; saw</button>
    \\        <button class="wbtn"    data-wave="3">&#8963; tri</button>
    \\      </div>
    \\    </div>
    \\
    \\    <!-- Envelope -->
    \\    <div class="panel">
    \\      <span class="panel-lbl">envelope</span>
    \\      <div class="env-row">
    \\        <span class="env-key">A</span>
    \\        <input type="range" id="atk" min="0.001" max="2"   step="0.001" value="0.01">
    \\        <span class="env-val" id="atk-v">10ms</span>
    \\      </div>
    \\      <div class="env-row">
    \\        <span class="env-key">D</span>
    \\        <input type="range" id="dec" min="0.001" max="2"   step="0.001" value="0.15">
    \\        <span class="env-val" id="dec-v">150ms</span>
    \\      </div>
    \\      <div class="env-row">
    \\        <span class="env-key">S</span>
    \\        <input type="range" id="sus" min="0"     max="1"   step="0.01"  value="0.7">
    \\        <span class="env-val" id="sus-v">70%</span>
    \\      </div>
    \\      <div class="env-row">
    \\        <span class="env-key">R</span>
    \\        <input type="range" id="rel" min="0.001" max="3"   step="0.001" value="0.4">
    \\        <span class="env-val" id="rel-v">400ms</span>
    \\      </div>
    \\    </div>
    \\
    \\    <!-- Timbre -->
    \\    <div class="panel">
    \\      <span class="panel-lbl">timbre</span>
    \\      <div class="tmb-row">
    \\        <span class="tmb-key">cut</span>
    \\        <input type="range" class="grn-thumb" id="flt" min="0" max="1" step="0.01" value="0.9">
    \\        <span class="tmb-val" id="flt-v">90%</span>
    \\      </div>
    \\      <div class="tmb-row">
    \\        <span class="tmb-key">vol</span>
    \\        <input type="range" class="grn-thumb" id="vol" min="0" max="1" step="0.01" value="0.8">
    \\        <span class="tmb-val" id="vol-v">80%</span>
    \\      </div>
    \\    </div>
    \\
    \\  </div><!-- /ctrls -->
    \\
    \\  <!-- Piano keyboard -->
    \\  <div class="piano-wrap">
    \\    <div class="piano" id="piano"></div>
    \\  </div>
    \\
    \\  <div class="kguide">
    \\    <strong>lower octave:</strong> z s x d c &nbsp;v g b h n j m &nbsp;&nbsp;
    \\    <strong>upper octave:</strong> q 2 w 3 e &nbsp;r 5 t 6 y 7 u
    \\  </div>
    \\
    \\  <div class="foot">
    \\    <a href="/">&#8592; merjs</a> &nbsp;&middot;&nbsp;
    \\    audio engine: <a href="https://github.com/justrach/merjs/blob/main/wasm/synth.zig">wasm/synth.zig</a> &nbsp;&middot;&nbsp;
    \\    zig 0.15 &rarr; wasm32 &rarr; audioworklet
    \\  </div>
    \\
    \\</div><!-- /shell -->
    \\
;

const script =
    \\<script>
    \\// ── Note map: [midi, isBlack, keyboardKey, whiteIndex] ────────────────────
    \\const NOTES = [
    \\  [48,false,'z',0],[49,true,'s',null],[50,false,'x',1],[51,true,'d',null],
    \\  [52,false,'c',2],[53,false,'v',3],[54,true,'g',null],[55,false,'b',4],
    \\  [56,true,'h',null],[57,false,'n',5],[58,true,'j',null],[59,false,'m',6],
    \\  [60,false,'q',7],[61,true,'2',null],[62,false,'w',8],[63,true,'3',null],
    \\  [64,false,'e',9],[65,false,'r',10],[66,true,'5',null],[67,false,'t',11],
    \\  [68,true,'6',null],[69,false,'y',12],[70,true,'7',null],[71,false,'u',13],
    \\];
    \\
    \\// Black key left positions (px) — centered between adjacent white keys
    \\// White key width = 50px, black key width = 30px
    \\const BK_LEFT = {49:35,51:85,54:185,56:235,58:285,61:385,63:435,66:535,68:585,70:635};
    \\
    \\const KEY_MAP = {};
    \\NOTES.forEach(([midi,,key]) => KEY_MAP[key] = midi);
    \\
    \\let wNode, analyser;
    \\const held = new Set();
    \\
    \\// ── Piano builder ─────────────────────────────────────────────────────────
    \\function buildPiano() {
    \\  const piano = document.getElementById('piano');
    \\  // White keys first (z-order below black)
    \\  NOTES.filter(n => !n[1]).forEach(([midi,,key,wi]) => {
    \\    const el = document.createElement('div');
    \\    el.className = 'key kw';
    \\    el.dataset.midi = midi;
    \\    el.style.left = (wi * 50) + 'px';
    \\    el.innerHTML = `<span class="khint">${key}</span>`;
    \\    el.addEventListener('mousedown', e => { e.preventDefault(); play(midi); });
    \\    el.addEventListener('mouseup',   () => stop(midi));
    \\    el.addEventListener('mouseleave',() => stop(midi));
    \\    el.addEventListener('touchstart', e => { e.preventDefault(); play(midi); }, {passive:false});
    \\    el.addEventListener('touchend',   () => stop(midi));
    \\    piano.appendChild(el);
    \\  });
    \\  // Black keys on top
    \\  NOTES.filter(n => n[1]).forEach(([midi,,key]) => {
    \\    const el = document.createElement('div');
    \\    el.className = 'key kb';
    \\    el.dataset.midi = midi;
    \\    el.style.left = BK_LEFT[midi] + 'px';
    \\    el.style.top = '0';
    \\    el.innerHTML = `<span class="khint">${key}</span>`;
    \\    el.addEventListener('mousedown', e => { e.preventDefault(); play(midi); });
    \\    el.addEventListener('mouseup',   () => stop(midi));
    \\    el.addEventListener('mouseleave',() => stop(midi));
    \\    el.addEventListener('touchstart', e => { e.preventDefault(); play(midi); }, {passive:false});
    \\    el.addEventListener('touchend',   () => stop(midi));
    \\    piano.appendChild(el);
    \\  });
    \\}
    \\
    \\function setPressed(midi, on) {
    \\  const el = document.querySelector(`[data-midi="${midi}"]`);
    \\  if (el) el.classList.toggle('on', on);
    \\}
    \\
    \\function play(midi) {
    \\  if (!wNode || held.has(midi)) return;
    \\  held.add(midi);
    \\  wNode.port.postMessage({ type:'note_on', note:midi, vel:100 });
    \\  setPressed(midi, true);
    \\}
    \\function stop(midi) {
    \\  if (!wNode || !held.has(midi)) return;
    \\  held.delete(midi);
    \\  wNode.port.postMessage({ type:'note_off', note:midi });
    \\  setPressed(midi, false);
    \\}
    \\
    \\function send(type, value) {
    \\  if (wNode) wNode.port.postMessage({ type, value: parseFloat(value) });
    \\}
    \\
    \\// ── Waveform selector ─────────────────────────────────────────────────────
    \\document.querySelectorAll('.wbtn').forEach(btn => {
    \\  btn.addEventListener('click', () => {
    \\    document.querySelectorAll('.wbtn').forEach(b => b.classList.remove('on'));
    \\    btn.classList.add('on');
    \\    send('set_wave', btn.dataset.wave);
    \\  });
    \\});
    \\
    \\// ── ADSR + timbre sliders ─────────────────────────────────────────────────
    \\function fmtMs(s) {
    \\  const ms = Math.round(s * 1000);
    \\  return ms >= 1000 ? (ms/1000).toFixed(2)+'s' : ms+'ms';
    \\}
    \\function pct(v) { return Math.round(v * 100) + '%'; }
    \\
    \\const sliders = [
    \\  ['atk','set_atk', v => fmtMs(v)],
    \\  ['dec','set_dec', v => fmtMs(v)],
    \\  ['sus','set_sus', v => pct(v)],
    \\  ['rel','set_rel', v => fmtMs(v)],
    \\  ['flt','set_flt', v => pct(v)],
    \\  ['vol','set_vol', v => pct(v)],
    \\];
    \\sliders.forEach(([id, msg, fmt]) => {
    \\  const el = document.getElementById(id);
    \\  const val = document.getElementById(id+'-v');
    \\  if (!el) return;
    \\  el.addEventListener('input', () => {
    \\    if (val) val.textContent = fmt(el.value);
    \\    send(msg, el.value);
    \\  });
    \\});
    \\
    \\// ── Keyboard input ────────────────────────────────────────────────────────
    \\window.addEventListener('keydown', e => {
    \\  if (e.repeat || e.ctrlKey || e.metaKey || e.altKey) return;
    \\  const midi = KEY_MAP[e.key.toLowerCase()];
    \\  if (midi !== undefined) { e.preventDefault(); play(midi); }
    \\});
    \\window.addEventListener('keyup', e => {
    \\  const midi = KEY_MAP[e.key.toLowerCase()];
    \\  if (midi !== undefined) stop(midi);
    \\});
    \\
    \\// ── Oscilloscope ─────────────────────────────────────────────────────────
    \\function drawOsc() {
    \\  requestAnimationFrame(drawOsc);
    \\  const canvas = document.getElementById('osc');
    \\  const g = canvas.getContext('2d');
    \\  const W = canvas.offsetWidth, H = canvas.offsetHeight;
    \\  canvas.width = W; canvas.height = H;
    \\
    \\  // Background
    \\  g.fillStyle = '#131318';
    \\  g.fillRect(0, 0, W, H);
    \\
    \\  // Grid
    \\  g.strokeStyle = '#22222c';
    \\  g.lineWidth = 1;
    \\  for (let i = 1; i < 4; i++) {
    \\    g.beginPath(); g.moveTo(0, H*i/4); g.lineTo(W, H*i/4); g.stroke();
    \\  }
    \\  for (let i = 1; i < 8; i++) {
    \\    g.beginPath(); g.moveTo(W*i/8, 0); g.lineTo(W*i/8, H); g.stroke();
    \\  }
    \\  // Centre line
    \\  g.strokeStyle = '#2e2e3a';
    \\  g.beginPath(); g.moveTo(0,H/2); g.lineTo(W,H/2); g.stroke();
    \\
    \\  if (!analyser) return;
    \\
    \\  const data = new Float32Array(analyser.frequencyBinCount);
    \\  analyser.getFloatTimeDomainData(data);
    \\
    \\  // Trigger: find first rising zero crossing for stable display
    \\  let start = 0;
    \\  for (let i = 1; i < data.length - 512; i++) {
    \\    if (data[i-1] < 0 && data[i] >= 0) { start = i; break; }
    \\  }
    \\
    \\  const slice = Math.min(data.length - start, W);
    \\  g.beginPath();
    \\  g.strokeStyle = '#00d084';
    \\  g.lineWidth = 1.5;
    \\  g.shadowColor = '#00d084';
    \\  g.shadowBlur = 7;
    \\  for (let i = 0; i < slice; i++) {
    \\    const x = (i / slice) * W;
    \\    const y = (0.5 - data[start + i] * 0.45) * H;
    \\    i === 0 ? g.moveTo(x, y) : g.lineTo(x, y);
    \\  }
    \\  g.stroke();
    \\}
    \\
    \\// ── Boot ─────────────────────────────────────────────────────────────────
    \\async function startSynth() {
    \\  document.getElementById('overlay').style.display = 'none';
    \\
    \\  const actx = new AudioContext();
    \\  document.getElementById('sr-badge').textContent = actx.sampleRate + ' Hz';
    \\
    \\  // Fetch WASM binary
    \\  const wasmBuf = await fetch('/synth.wasm').then(r => r.arrayBuffer());
    \\
    \\  // AudioWorklet processor source — inlined as a blob URL
    \\  const procSrc = `
    \\class SynthProc extends AudioWorkletProcessor {
    \\  constructor(opts) {
    \\    super();
    \\    const mod = new WebAssembly.Module(opts.processorOptions.wasm);
    \\    this.w = new WebAssembly.Instance(mod).exports;
    \\    this.port.onmessage = ({data:d}) => {
    \\      const w = this.w;
    \\      if      (d.type==='note_on')  w.note_on(d.note|0, d.vel|0);
    \\      else if (d.type==='note_off') w.note_off(d.note|0);
    \\      else if (d.type==='set_wave') w.set_wave(d.value|0);
    \\      else if (d.type==='set_atk')  w.set_atk(d.value);
    \\      else if (d.type==='set_dec')  w.set_dec(d.value);
    \\      else if (d.type==='set_sus')  w.set_sus(d.value);
    \\      else if (d.type==='set_rel')  w.set_rel(d.value);
    \\      else if (d.type==='set_flt')  w.set_flt(d.value);
    \\      else if (d.type==='set_vol')  w.set_vol(d.value);
    \\    };
    \\  }
    \\  process(inputs, outputs) {
    \\    const ch = outputs[0][0];
    \\    if (!ch || !this.w) return true;
    \\    this.w.fill(ch.length, sampleRate);
    \\    const ptr = this.w.buf_ptr();
    \\    ch.set(new Float32Array(this.w.memory.buffer, ptr, ch.length));
    \\    return true;
    \\  }
    \\}
    \\registerProcessor('synth-proc', SynthProc);
    \\`;
    \\  const blob = new Blob([procSrc], { type:'application/javascript' });
    \\  const url  = URL.createObjectURL(blob);
    \\  await actx.audioWorklet.addModule(url);
    \\  URL.revokeObjectURL(url);
    \\
    \\  wNode = new AudioWorkletNode(actx, 'synth-proc', {
    \\    processorOptions: { wasm: wasmBuf },
    \\    numberOfInputs: 0,
    \\    numberOfOutputs: 1,
    \\    outputChannelCount: [1],
    \\  });
    \\
    \\  analyser = actx.createAnalyser();
    \\  analyser.fftSize = 2048;
    \\  wNode.connect(analyser);
    \\  analyser.connect(actx.destination);
    \\
    \\  // Mark WASM active
    \\  const badge = document.getElementById('wasm-badge');
    \\  badge.classList.remove('inactive');
    \\  badge.textContent = '◉ WASM';
    \\}
    \\
    \\document.getElementById('startbtn').addEventListener('click', startSynth);
    \\buildPiano();
    \\drawOsc();
    \\</script>
;
