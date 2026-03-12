const mer = @import("mer");

pub const meta: mer.Meta = .{
    .title = "Budget AI Sandbox",
    .description = "Ask questions about Singapore's FY2026 Budget Statement. Powered by R2 grep search — no embeddings, no vector DB.",
    .og_title = "Budget AI Sandbox \u{2014} merjs",
    .og_description = "Retrieval via grep on Cloudflare R2. Zero embeddings.",
    .twitter_card = "summary",
    .extra_head = "<script src=\"https://cdn.jsdelivr.net/npm/marked/marked.min.js\"></script><style>" ++ page_css ++ "</style>",
};

pub fn render(req: mer.Request) mer.Response {
    _ = req;
    return mer.html(html);
}

const html =
    \\<div class="sandbox">
    \\  <div class="sandbox-header">
    \\    <h1>Budget AI <span class="red">Sandbox</span></h1>
    \\    <p class="sub">Ask anything about Singapore's FY2026 Budget Statement.</p>
    \\    <div class="method-badge">
    \\      <span class="badge-dot"></span>
    \\      retrieval via <strong>R2 grep</strong> &mdash; no embeddings, no vector DB
    \\    </div>
    \\    </div>
    \\  </div>
    \\
    \\  <details class="how-it-works">
    \\    <summary>How does this work?</summary>
    \\    <div class="how-content">
    \\      <ol>
    \\        <li><strong>PDF &rarr; text chunks</strong> &mdash; the budget PDF is split into ~500-word overlapping chunks and stored as JSON on <strong>Cloudflare R2</strong></li>
    \\        <li><strong>Keyword extraction</strong> &mdash; your question is sent to an LLM to extract search keywords (with synonyms)</li>
    \\        <li><strong>R2 grep</strong> &mdash; every chunk is scored by keyword frequency. Top 8 matches are returned. No embeddings, no vector DB &mdash; just string matching on ~93KB of text</li>
    \\        <li><strong>LLM answer</strong> &mdash; matched chunks + your question are sent to a language model, which generates a cited answer</li>
    \\      </ol>
    \\      <p class="how-note">The entire retrieval pipeline runs on a single Cloudflare Worker. R2 reads from the same datacenter are sub-millisecond. Total retrieval cost: <strong>$0</strong>.</p>
    \\    </div>
    \\  </details>
    \\
    \\  <div class="chat-messages" id="chat-messages">
    \\    <div class="msg msg-system">
    \\      <div class="msg-content">
    \\        Hi! I can answer questions about the <strong>FY2026 Singapore Budget Statement</strong>.
    \\        I search the document using keyword matching on Cloudflare R2 &mdash; no embeddings needed.
    \\        Try asking about education spending, healthcare, or defense allocations.
    \\      </div>
    \\    </div>
    \\  </div>
    \\
    \\  <div class="suggestions" id="suggestions">
    \\    <button class="chip" onclick="askQuestion('What are the key highlights of the FY2026 Budget?')">Key highlights?</button>
    \\    <button class="chip" onclick="askQuestion('How much is allocated for education?')">Education spending?</button>
    \\    <button class="chip" onclick="askQuestion('What are the new taxes introduced?')">New taxes?</button>
    \\  </div>
    \\
    \\  <form class="chat-form" id="chat-form" onsubmit="return handleSubmit(event)">
    \\    <input type="text" id="chat-input" placeholder="Ask about FY2026 Budget..." autocomplete="off">
    \\    <button type="submit" id="chat-send">Ask</button>
    \\  </form>
    \\</div>
    \\
    \\<script>
    \\const msgs = document.getElementById('chat-messages');
    \\const input = document.getElementById('chat-input');
    \\const sugEl = document.getElementById('suggestions');
    \\const sendBtn = document.getElementById('chat-send');
    \\let busy = false;
    \\
    \\function addMsg(role, content, meta) {
    \\  const d = document.createElement('div');
    \\  d.className = 'msg msg-' + role;
    \\  let html = '<div class="msg-content">' + content + '</div>';
    \\  if (meta) html += '<div class="msg-meta">' + meta + '</div>';
    \\  d.innerHTML = html;
    \\  msgs.appendChild(d);
    \\  msgs.scrollTop = msgs.scrollHeight;
    \\  return d;
    \\}
    \\
    \\async function askQuestion(q) {
    \\  if (busy || !q.trim()) return;
    \\  busy = true;
    \\  sendBtn.disabled = true;
    \\  input.value = '';
    \\  sugEl.innerHTML = '';
    \\
    \\  addMsg('user', q);
    \\  const loading = addMsg('assistant', '<span class="loading-dots">Searching R2 chunks</span>');
    \\
    \\  try {
    \\    const res = await fetch('/api/budget-ai', {
    \\      method: 'POST',
    \\      headers: { 'Content-Type': 'application/json' },
    \\      body: JSON.stringify({ question: q }),
    \\    });
    \\    const data = await res.json();
    \\
    \\    if (data.error) {
    \\      loading.querySelector('.msg-content').innerHTML = '<span class="error">' + data.error + '</span>';
    \\    } else {
    \\      const formatted = typeof marked !== 'undefined' ? marked.parse(data.answer) : data.answer.replace(/\n/g, '<br>');
    \\      loading.querySelector('.msg-content').innerHTML = formatted;
    \\      const meta = 'grep matched ' + data.chunks_matched + '/' + data.chunks_searched
    \\        + ' chunks \u{00B7} keywords: ' + data.keywords;
    \\      const metaEl = document.createElement('div');
    \\      metaEl.className = 'msg-meta';
    \\      metaEl.textContent = meta;
    \\      loading.appendChild(metaEl);
    \\
    \\      // Fetch suggestions
    \\      try {
    \\        const sugRes = await fetch('/api/budget-suggestions', {
    \\          method: 'POST',
    \\          headers: { 'Content-Type': 'application/json' },
    \\          body: JSON.stringify({ question: q, answer: data.answer }),
    \\        });
    \\        const sugData = await sugRes.json();
    \\        if (sugData.suggestions && sugData.suggestions.length) {
    \\          sugEl.innerHTML = sugData.suggestions.map(function(s) {
    \\            return '<button class="chip" onclick="askQuestion(\'' + s.replace(/'/g, "\\'") + '\')">' + s + '</button>';
    \\          }).join('');
    \\        }
    \\      } catch(e) {}
    \\    }
    \\  } catch(e) {
    \\    loading.querySelector('.msg-content').innerHTML = '<span class="error">Network error: ' + e.message + '</span>';
    \\  }
    \\
    \\  busy = false;
    \\  sendBtn.disabled = false;
    \\  input.focus();
    \\}
    \\
    \\function handleSubmit(e) {
    \\  e.preventDefault();
    \\  askQuestion(input.value);
    \\  return false;
    \\}
    \\</script>
;

const page_css =
    \\.sandbox { max-width: 700px; margin: 0 auto; }
    \\.sandbox-header { margin-bottom: 24px; }
    \\h1 { font-family: 'DM Serif Display', Georgia, serif; font-size: 28px; letter-spacing: -0.02em; }
    \\.red { color: var(--red); }
    \\.sub { font-size: 13px; color: var(--muted); margin-top: 6px; }
    \\.method-badge {
    \\  display: inline-flex; align-items: center; gap: 8px;
    \\  margin-top: 12px; padding: 6px 14px;
    \\  background: var(--bg2); border: 1px solid var(--border);
    \\  border-radius: 100px; font-size: 11px; color: var(--muted);
    \\}
    \\.badge-dot { width: 6px; height: 6px; border-radius: 50%; background: #22c55e; flex-shrink: 0; }
    \\.method-badge strong { color: var(--text); }
    \\/* Chat */
    \\.chat-messages {
    \\  display: flex; flex-direction: column; gap: 12px;
    \\  max-height: 500px; overflow-y: auto;
    \\  padding: 16px 0; margin-bottom: 12px;
    \\}
    \\.msg { display: flex; flex-direction: column; gap: 4px; }
    \\.msg-content {
    \\  padding: 12px 16px; border-radius: 12px;
    \\  font-size: 14px; line-height: 1.6; max-width: 90%;
    \\}
    \\.msg-user .msg-content {
    \\  background: var(--red); color: var(--bg);
    \\  align-self: flex-end; border-bottom-right-radius: 4px;
    \\}
    \\.msg-user { align-items: flex-end; }
    \\.msg-assistant .msg-content {
    \\  background: var(--bg2); border: 1px solid var(--border);
    \\  border-bottom-left-radius: 4px;
    \\}
    \\}
    \\/* Markdown inside assistant messages */
    \\.msg-assistant .msg-content h1,
    \\.msg-assistant .msg-content h2,
    \\.msg-assistant .msg-content h3 {
    \\  font-family: 'DM Serif Display', Georgia, serif;
    \\  margin: 12px 0 6px; line-height: 1.3;
    \\}
    \\.msg-assistant .msg-content h1 { font-size: 18px; }
    \\.msg-assistant .msg-content h2 { font-size: 16px; }
    \\.msg-assistant .msg-content h3 { font-size: 14px; font-weight: 600; }
    \\.msg-assistant .msg-content ul, .msg-assistant .msg-content ol {
    \\  padding-left: 20px; margin: 8px 0;
    \\}
    \\.msg-assistant .msg-content li { margin: 4px 0; }
    \\.msg-assistant .msg-content strong { color: var(--text); }
    \\.msg-assistant .msg-content code {
    \\  background: var(--bg3); padding: 2px 6px; border-radius: 4px;
    \\  font-size: 12px; font-family: 'SF Mono', 'Fira Code', monospace;
    \\}
    \\.msg-assistant .msg-content pre {
    \\  background: var(--bg3); padding: 12px; border-radius: 8px;
    \\  overflow-x: auto; margin: 8px 0;
    \\}
    \\.msg-assistant .msg-content pre code { background: none; padding: 0; }
    \\.msg-assistant .msg-content p { margin: 6px 0; }
    \\.msg-assistant .msg-content blockquote {
    \\  border-left: 3px solid var(--red); padding-left: 12px;
    \\  margin: 8px 0; color: var(--muted); font-style: italic;
    \\}
    \\.msg-system .msg-content {
    \\  background: var(--bg3); color: var(--muted);
    \\  font-size: 13px; border-radius: 8px;
    \\}
    \\.msg-meta {
    \\  font-size: 10px; color: var(--muted); padding: 0 4px;
    \\  font-family: 'SF Mono', 'Fira Code', monospace;
    \\}
    \\.error { color: var(--red); }
    \\.loading-dots::after { content: '...'; animation: dots 1.5s infinite; }
    \\@keyframes dots { 0% { content: '.'; } 33% { content: '..'; } 66% { content: '...'; } }
    \\/* Suggestions */
    \\.suggestions { display: flex; gap: 8px; flex-wrap: wrap; margin-bottom: 12px; }
    \\.chip {
    \\  padding: 6px 14px; border-radius: 100px;
    \\  background: var(--bg2); border: 1px solid var(--border);
    \\  font-size: 12px; color: var(--muted); cursor: pointer;
    \\  font-family: 'DM Sans', sans-serif; transition: all 0.15s;
    \\}
    \\.chip:hover { color: var(--text); border-color: var(--text); }
    \\/* Form */
    \\.chat-form {
    \\  display: flex; gap: 8px;
    \\  background: var(--bg2); border: 1px solid var(--border);
    \\  border-radius: 12px; padding: 8px;
    \\}
    \\.chat-form input {
    \\  flex: 1; border: none; background: transparent;
    \\  font-size: 14px; color: var(--text); outline: none;
    \\  font-family: 'DM Sans', sans-serif; padding: 4px 8px;
    \\}
    \\.chat-form input::placeholder { color: var(--muted); }
    \\.chat-form button {
    \\  padding: 8px 20px; border-radius: 8px; border: none;
    \\  background: var(--red); color: var(--bg);
    \\  font-size: 13px; font-weight: 600; cursor: pointer;
    \\  font-family: 'DM Sans', sans-serif; transition: opacity 0.15s;
    \\}
    \\.chat-form button:hover { opacity: 0.88; }
    \\.chat-form button:disabled { opacity: 0.5; cursor: not-allowed; }
;
