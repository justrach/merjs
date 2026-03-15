const mer = @import("mer");

pub const meta: mer.Meta = .{
    .title = "Kanban — merjs",
    .description = "Drag-and-drop Kanban board. merjs renders the shell; all interactivity is vanilla JS with localStorage. No React. No database.",
    .extra_head = "<style>" ++ css ++ "</style>",
};

pub fn render(req: mer.Request) mer.Response {
    _ = req;
    return mer.html(html);
}

const html =
    \\<div class="kb-app">
    \\  <header class="kb-header">
    \\    <div class="kb-wordmark">
    \\      <span class="kb-logo">&#127981;</span>
    \\      <span>mer<span class="red">board</span></span>
    \\      <span class="kb-badge">merjs</span>
    \\    </div>
    \\    <div class="kb-header-actions">
    \\      <button class="btn-ghost" onclick="clearBoard()">Reset board</button>
    \\      <button class="btn-primary" onclick="addColumn()">+ Add column</button>
    \\    </div>
    \\  </header>
    \\
    \\  <div class="kb-board" id="board"></div>
    \\
    \\  <footer class="kb-footer">
    \\    Built with <a href="https://github.com/justrach/merjs">merjs</a> &middot;
    \\    Zig &rarr; WASM &middot; zero Node.js &middot;
    \\    state in <code>localStorage</code> &middot;
    \\    <a href="https://github.com/remix-run/example-trellix">compare: Remix Trellix</a>
    \\  </footer>
    \\</div>
    \\
    \\<script>
    \\// ── State ──────────────────────────────────────────────────────────────────
    \\const STORE_KEY = 'merboard_v1';
    \\
    \\const DEFAULT_BOARD = {
    \\  columns: [
    \\    { id: 'col-1', title: 'To Do', cards: [
    \\      { id: 'c-1', text: 'Set up project structure' },
    \\      { id: 'c-2', text: 'Write landing page copy' },
    \\      { id: 'c-3', text: 'Design colour palette' },
    \\    ]},
    \\    { id: 'col-2', title: 'In Progress', cards: [
    \\      { id: 'c-4', text: 'Build Kanban board demo' },
    \\      { id: 'c-5', text: 'Streaming SSR weather cards' },
    \\    ]},
    \\    { id: 'col-3', title: 'Done', cards: [
    \\      { id: 'c-6', text: 'File-based routing' },
    \\      { id: 'c-7', text: 'Cloudflare Workers deploy' },
    \\      { id: 'c-8', text: 'Zero npm dependencies' },
    \\    ]},
    \\  ]
    \\};
    \\
    \\function load() {
    \\  try {
    \\    const raw = localStorage.getItem(STORE_KEY);
    \\    return raw ? JSON.parse(raw) : structuredClone(DEFAULT_BOARD);
    \\  } catch { return structuredClone(DEFAULT_BOARD); }
    \\}
    \\
    \\function save(board) {
    \\  localStorage.setItem(STORE_KEY, JSON.stringify(board));
    \\}
    \\
    \\let board = load();
    \\let uid = Date.now();
    \\function nextId() { return 'id-' + (++uid); }
    \\
    \\// ── Drag state ─────────────────────────────────────────────────────────────
    \\let drag = null; // { cardId, fromColId }
    \\
    \\// ── Render ─────────────────────────────────────────────────────────────────
    \\function render() {
    \\  const root = document.getElementById('board');
    \\  root.innerHTML = '';
    \\  for (const col of board.columns) root.appendChild(buildCol(col));
    \\  root.appendChild(buildAddColBtn());
    \\}
    \\
    \\function buildCol(col) {
    \\  const el = document.createElement('div');
    \\  el.className = 'kb-col';
    \\  el.dataset.colId = col.id;
    \\
    \\  // Header
    \\  const hdr = document.createElement('div');
    \\  hdr.className = 'kb-col-header';
    \\
    \\  const titleEl = document.createElement('span');
    \\  titleEl.className = 'kb-col-title';
    \\  titleEl.textContent = col.title;
    \\  titleEl.ondblclick = () => editColTitle(col.id, titleEl);
    \\
    \\  const count = document.createElement('span');
    \\  count.className = 'kb-col-count';
    \\  count.textContent = col.cards.length;
    \\
    \\  const delBtn = document.createElement('button');
    \\  delBtn.className = 'kb-col-del';
    \\  delBtn.textContent = '×';
    \\  delBtn.title = 'Delete column';
    \\  delBtn.onclick = () => deleteColumn(col.id);
    \\
    \\  hdr.appendChild(titleEl);
    \\  hdr.appendChild(count);
    \\  hdr.appendChild(delBtn);
    \\
    \\  // Cards
    \\  const cards = document.createElement('div');
    \\  cards.className = 'kb-cards';
    \\  cards.dataset.colId = col.id;
    \\
    \\  for (const card of col.cards) cards.appendChild(buildCard(card, col.id));
    \\
    \\  // Drop zone events
    \\  cards.addEventListener('dragover', e => {
    \\    e.preventDefault();
    \\    cards.classList.add('drag-over');
    \\    const after = getDragAfter(cards, e.clientY);
    \\    const ghost = document.querySelector('.drag-ghost');
    \\    if (ghost) {
    \\      if (after) cards.insertBefore(ghost, after);
    \\      else cards.appendChild(ghost);
    \\    }
    \\  });
    \\  cards.addEventListener('dragleave', () => cards.classList.remove('drag-over'));
    \\  cards.addEventListener('drop', e => {
    \\    e.preventDefault();
    \\    cards.classList.remove('drag-over');
    \\    if (!drag) return;
    \\    const toColId = cards.dataset.colId;
    \\    const after = getDragAfter(cards, e.clientY);
    \\    moveCard(drag.cardId, drag.fromColId, toColId, after ? after.dataset.cardId : null);
    \\  });
    \\
    \\  // Add card input
    \\  const addWrap = document.createElement('div');
    \\  addWrap.className = 'kb-add-card';
    \\
    \\  const input = document.createElement('input');
    \\  input.type = 'text';
    \\  input.placeholder = 'Add a card...';
    \\  input.className = 'kb-add-input';
    \\  input.onkeydown = e => {
    \\    if (e.key === 'Enter' && input.value.trim()) {
    \\      addCard(col.id, input.value.trim());
    \\      input.value = '';
    \\    }
    \\    if (e.key === 'Escape') input.blur();
    \\  };
    \\
    \\  const addBtn = document.createElement('button');
    \\  addBtn.className = 'btn-add';
    \\  addBtn.textContent = '+ Add';
    \\  addBtn.onclick = () => {
    \\    if (input.value.trim()) { addCard(col.id, input.value.trim()); input.value = ''; }
    \\    else input.focus();
    \\  };
    \\
    \\  addWrap.appendChild(input);
    \\  addWrap.appendChild(addBtn);
    \\
    \\  el.appendChild(hdr);
    \\  el.appendChild(cards);
    \\  el.appendChild(addWrap);
    \\  return el;
    \\}
    \\
    \\function buildCard(card, colId) {
    \\  const el = document.createElement('div');
    \\  el.className = 'kb-card';
    \\  el.draggable = true;
    \\  el.dataset.cardId = card.id;
    \\
    \\  const text = document.createElement('span');
    \\  text.className = 'kb-card-text';
    \\  text.textContent = card.text;
    \\  text.ondblclick = () => editCard(card.id, colId, text);
    \\
    \\  const del = document.createElement('button');
    \\  del.className = 'kb-card-del';
    \\  del.textContent = '×';
    \\  del.onclick = () => deleteCard(card.id, colId);
    \\
    \\  el.appendChild(text);
    \\  el.appendChild(del);
    \\
    \\  el.addEventListener('dragstart', e => {
    \\    drag = { cardId: card.id, fromColId: colId };
    \\    el.classList.add('dragging');
    \\    // create ghost
    \\    const ghost = el.cloneNode(true);
    \\    ghost.classList.add('drag-ghost');
    \\    ghost.style.opacity = '0.4';
    \\    document.getElementById('board').appendChild(ghost);
    \\    e.dataTransfer.effectAllowed = 'move';
    \\    setTimeout(() => el.style.visibility = 'hidden', 0);
    \\  });
    \\
    \\  el.addEventListener('dragend', () => {
    \\    el.classList.remove('dragging');
    \\    el.style.visibility = '';
    \\    drag = null;
    \\    document.querySelectorAll('.drag-ghost').forEach(g => g.remove());
    \\    document.querySelectorAll('.drag-over').forEach(c => c.classList.remove('drag-over'));
    \\  });
    \\
    \\  return el;
    \\}
    \\
    \\function buildAddColBtn() {
    \\  const el = document.createElement('button');
    \\  el.className = 'kb-add-col-btn';
    \\  el.innerHTML = '<span>+</span> Add column';
    \\  el.onclick = addColumn;
    \\  return el;
    \\}
    \\
    \\function getDragAfter(container, y) {
    \\  const cards = [...container.querySelectorAll('.kb-card:not(.dragging):not(.drag-ghost)')];
    \\  return cards.reduce((closest, child) => {
    \\    const box = child.getBoundingClientRect();
    \\    const offset = y - box.top - box.height / 2;
    \\    if (offset < 0 && offset > (closest.offset ?? -Infinity))
    \\      return { offset, el: child };
    \\    return closest;
    \\  }, {}).el;
    \\}
    \\
    \\// ── Mutations ──────────────────────────────────────────────────────────────
    \\function addCard(colId, text) {
    \\  const col = board.columns.find(c => c.id === colId);
    \\  if (!col) return;
    \\  col.cards.push({ id: nextId(), text });
    \\  save(board);
    \\  render();
    \\}
    \\
    \\function deleteCard(cardId, colId) {
    \\  const col = board.columns.find(c => c.id === colId);
    \\  if (!col) return;
    \\  col.cards = col.cards.filter(c => c.id !== cardId);
    \\  save(board);
    \\  render();
    \\}
    \\
    \\function editCard(cardId, colId, el) {
    \\  const col = board.columns.find(c => c.id === colId);
    \\  const card = col?.cards.find(c => c.id === cardId);
    \\  if (!card) return;
    \\
    \\  const input = document.createElement('input');
    \\  input.type = 'text';
    \\  input.value = card.text;
    \\  input.className = 'kb-inline-edit';
    \\  el.replaceWith(input);
    \\  input.focus();
    \\  input.select();
    \\
    \\  const commit = () => {
    \\    const val = input.value.trim();
    \\    if (val) card.text = val;
    \\    save(board);
    \\    render();
    \\  };
    \\  input.onblur = commit;
    \\  input.onkeydown = e => { if (e.key === 'Enter') commit(); if (e.key === 'Escape') render(); };
    \\}
    \\
    \\function moveCard(cardId, fromColId, toColId, afterCardId) {
    \\  const fromCol = board.columns.find(c => c.id === fromColId);
    \\  const toCol = board.columns.find(c => c.id === toColId);
    \\  if (!fromCol || !toCol) return;
    \\
    \\  const card = fromCol.cards.find(c => c.id === cardId);
    \\  if (!card) return;
    \\
    \\  fromCol.cards = fromCol.cards.filter(c => c.id !== cardId);
    \\
    \\  if (afterCardId) {
    \\    const idx = toCol.cards.findIndex(c => c.id === afterCardId);
    \\    toCol.cards.splice(idx, 0, card);
    \\  } else {
    \\    toCol.cards.push(card);
    \\  }
    \\
    \\  save(board);
    \\  render();
    \\}
    \\
    \\function addColumn() {
    \\  const title = prompt('Column name:');
    \\  if (!title?.trim()) return;
    \\  board.columns.push({ id: nextId(), title: title.trim(), cards: [] });
    \\  save(board);
    \\  render();
    \\}
    \\
    \\function deleteColumn(colId) {
    \\  board.columns = board.columns.filter(c => c.id !== colId);
    \\  save(board);
    \\  render();
    \\}
    \\
    \\function editColTitle(colId, el) {
    \\  const col = board.columns.find(c => c.id === colId);
    \\  if (!col) return;
    \\  const input = document.createElement('input');
    \\  input.type = 'text';
    \\  input.value = col.title;
    \\  input.className = 'kb-inline-edit kb-col-title-edit';
    \\  el.replaceWith(input);
    \\  input.focus();
    \\  input.select();
    \\  const commit = () => {
    \\    const val = input.value.trim();
    \\    if (val) col.title = val;
    \\    save(board);
    \\    render();
    \\  };
    \\  input.onblur = commit;
    \\  input.onkeydown = e => { if (e.key === 'Enter') commit(); if (e.key === 'Escape') render(); };
    \\}
    \\
    \\function clearBoard() {
    \\  if (!confirm('Reset board to defaults?')) return;
    \\  board = structuredClone(DEFAULT_BOARD);
    \\  save(board);
    \\  render();
    \\}
    \\
    \\// ── Boot ───────────────────────────────────────────────────────────────────
    \\render();
    \\</script>
;

const css =
    \\.kb-app { display:flex; flex-direction:column; min-height:100vh; }
    \\.kb-header { display:flex; align-items:center; justify-content:space-between; padding:14px 24px; background:var(--bg2); border-bottom:1px solid var(--border); position:sticky; top:0; z-index:10; }
    \\.kb-wordmark { display:flex; align-items:center; gap:8px; font-family:'DM Serif Display',Georgia,serif; font-size:20px; letter-spacing:-0.02em; }
    \\.kb-logo { font-size:22px; }
    \\.red { color:var(--red); }
    \\.kb-badge { font-family:'DM Sans',sans-serif; font-size:10px; font-weight:600; background:var(--text); color:var(--bg); padding:2px 7px; border-radius:20px; letter-spacing:0.04em; }
    \\.kb-header-actions { display:flex; gap:8px; }
    \\.btn-primary { background:var(--text); color:var(--bg); border:none; border-radius:6px; padding:7px 14px; font-size:13px; font-weight:500; cursor:pointer; font-family:inherit; transition:opacity 0.15s; }
    \\.btn-primary:hover { opacity:0.8; }
    \\.btn-ghost { background:transparent; color:var(--muted); border:1px solid var(--border); border-radius:6px; padding:7px 14px; font-size:13px; cursor:pointer; font-family:inherit; transition:all 0.15s; }
    \\.btn-ghost:hover { background:var(--bg3); color:var(--text); }
    \\.kb-board { display:flex; align-items:flex-start; gap:14px; padding:24px; overflow-x:auto; flex:1; }
    \\.kb-col { background:var(--bg2); border:1px solid var(--border); border-radius:12px; width:280px; min-width:280px; display:flex; flex-direction:column; max-height:calc(100vh - 130px); }
    \\.kb-col-header { display:flex; align-items:center; gap:8px; padding:14px 16px 10px; }
    \\.kb-col-title { font-weight:600; font-size:14px; flex:1; cursor:default; }
    \\.kb-col-count { background:var(--bg3); color:var(--muted); font-size:11px; font-weight:600; padding:2px 7px; border-radius:10px; min-width:20px; text-align:center; }
    \\.kb-col-del { background:none; border:none; color:var(--muted); cursor:pointer; font-size:18px; line-height:1; padding:0 2px; border-radius:4px; opacity:0; transition:opacity 0.15s; }
    \\.kb-col:hover .kb-col-del { opacity:1; }
    \\.kb-col-del:hover { color:var(--red); background:var(--bg3); }
    \\.kb-cards { flex:1; overflow-y:auto; padding:4px 10px; display:flex; flex-direction:column; gap:8px; min-height:60px; transition:background 0.15s; }
    \\.kb-cards.drag-over { background:rgba(232,37,31,0.04); border-radius:8px; }
    \\.kb-card { background:var(--bg); border:1px solid var(--border); border-radius:8px; padding:10px 12px; display:flex; align-items:flex-start; gap:8px; cursor:grab; transition:box-shadow 0.15s, transform 0.15s; position:relative; }
    \\.kb-card:hover { box-shadow:0 2px 10px rgba(0,0,0,0.07); transform:translateY(-1px); }
    \\.kb-card:active { cursor:grabbing; }
    \\.kb-card.dragging { opacity:0.4; }
    \\.kb-card-text { flex:1; font-size:13px; line-height:1.5; cursor:default; word-break:break-word; }
    \\.kb-card-del { background:none; border:none; color:var(--muted); cursor:pointer; font-size:16px; line-height:1; padding:0; opacity:0; transition:opacity 0.15s; flex-shrink:0; margin-top:1px; }
    \\.kb-card:hover .kb-card-del { opacity:1; }
    \\.kb-card-del:hover { color:var(--red); }
    \\.kb-add-card { padding:8px 10px 12px; display:flex; gap:6px; }
    \\.kb-add-input { flex:1; background:var(--bg3); border:1px solid transparent; border-radius:6px; padding:7px 10px; font-size:13px; font-family:inherit; color:var(--text); outline:none; transition:border-color 0.15s, background 0.15s; }
    \\.kb-add-input:focus { background:var(--bg); border-color:var(--border); }
    \\.kb-add-input::placeholder { color:var(--muted); }
    \\.btn-add { background:var(--text); color:var(--bg); border:none; border-radius:6px; padding:7px 12px; font-size:12px; font-weight:600; cursor:pointer; font-family:inherit; white-space:nowrap; transition:opacity 0.15s; }
    \\.btn-add:hover { opacity:0.8; }
    \\.kb-add-col-btn { background:var(--bg2); border:1px dashed var(--border); border-radius:12px; width:280px; min-width:280px; padding:20px; font-size:14px; color:var(--muted); cursor:pointer; font-family:inherit; transition:all 0.15s; display:flex; align-items:center; justify-content:center; gap:8px; align-self:flex-start; }
    \\.kb-add-col-btn:hover { background:var(--bg3); color:var(--text); border-color:var(--text); }
    \\.kb-inline-edit { flex:1; background:var(--bg); border:1px solid var(--red); border-radius:4px; padding:2px 6px; font-size:13px; font-family:inherit; color:var(--text); outline:none; width:100%; }
    \\.kb-col-title-edit { font-weight:600; font-size:14px; }
    \\.kb-footer { padding:16px 24px; font-size:11px; color:var(--muted); border-top:1px solid var(--border); text-align:center; }
    \\.kb-footer a { text-decoration:underline; text-underline-offset:2px; }
    \\.kb-footer code { font-size:10px; background:var(--bg3); padding:1px 4px; border-radius:3px; }
;
