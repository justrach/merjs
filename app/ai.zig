const mer = @import("mer");

pub const meta: mer.Meta = .{
    .title = "Budget 2026 AI",
    .description = "Ask questions about Singapore's FY2026 Budget Statement — powered by gpt-5-nano and EmergentDB RAG.",
    .extra_head = "<style>" ++ page_css ++ "</style>",
};

pub fn render(req: mer.Request) mer.Response {
    _ = req;
    return mer.html(html);
}

const html =
    \\<div class="ai-page">
    \\
    \\<nav class="sg-nav">
    \\  <a href="/" class="sg-nav-link">Dashboard</a>
    \\  <a href="/weather" class="sg-nav-link">Weather</a>
    \\  <a href="/environment" class="sg-nav-link">Environment</a>
    \\  <a href="/explore" class="sg-nav-link">Explore</a>
    \\  <a href="/ai" class="sg-nav-link active">AI</a>
    \\</nav>
    \\
    \\<div class="ai-header">
    \\  <h1>Budget <span class="red">2026</span> AI</h1>
    \\  <p class="subtitle">Ask questions about Singapore's FY2026 Budget Statement &mdash; powered by gpt-5-nano + EmergentDB</p>
    \\</div>
    \\
    \\<div class="examples" id="examples">
    \\  <button class="example-btn" onclick="askExample(this)">What are the key tax changes?</button>
    \\  <button class="example-btn" onclick="askExample(this)">How much is allocated for healthcare?</button>
    \\  <button class="example-btn" onclick="askExample(this)">What support is there for businesses?</button>
    \\  <button class="example-btn" onclick="askExample(this)">What are the GST changes?</button>
    \\  <button class="example-btn" onclick="askExample(this)">What is the overall fiscal position?</button>
    \\</div>
    \\
    \\<div class="chat" id="chat"></div>
    \\
    \\<div class="input-bar">
    \\  <input type="text" class="chat-input" id="input"
    \\    placeholder="Ask about the FY2026 Budget..."
    \\    onkeydown="if(event.key==='Enter'&&!event.shiftKey){event.preventDefault();sendMessage()}">
    \\  <button class="send-btn" id="send-btn" onclick="sendMessage()" aria-label="Send">
    \\    <svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.5"><path d="M22 2L11 13M22 2l-7 20-4-9-9-4z"/></svg>
    \\  </button>
    \\</div>
    \\
    \\<p class="footer-note">
    \\  Powered by <strong>gpt-5-nano</strong> &middot;
    \\  Chunks in <strong>EmergentDB</strong> &middot;
    \\  served by <code>merjs</code>
    \\</p>
    \\
    \\</div><!-- .ai-page -->
    \\
    \\<script>
    \\const chat = document.getElementById('chat');
    \\const input = document.getElementById('input');
    \\let isLoading = false;
    \\
    \\function addMessage(role, html){
    \\  const div = document.createElement('div');
    \\  div.className = 'msg msg-'+role;
    \\  div.innerHTML = '<div class="msg-role">'+(role==='user'?'You':'AI')+'</div>'
    \\    +'<div class="msg-text">'+html+'</div>';
    \\  chat.appendChild(div);
    \\  div.scrollIntoView({behavior:'smooth', block:'end'});
    \\  return div;
    \\}
    \\
    \\function formatText(text){
    \\  return text
    \\    .replace(/&/g,'&amp;').replace(/</g,'&lt;').replace(/>/g,'&gt;')
    \\    .replace(/\*\*(.*?)\*\*/g,'<strong>$1</strong>')
    \\    .replace(/\*(.*?)\*/g,'<em>$1</em>')
    \\    .replace(/`(.*?)`/g,'<code>$1</code>')
    \\    .replace(/\n/g,'<br>');
    \\}
    \\
    \\function askExample(btn){
    \\  input.value = btn.textContent;
    \\  sendMessage();
    \\  document.getElementById('examples').style.display='none';
    \\}
    \\
\\async function sendMessage(q){
\\  if(!q) q = input.value.trim();
\\  if(!q || isLoading) return;
\\  isLoading = true;
\\  input.value = '';
\\  document.getElementById('send-btn').disabled = true;
\\  document.getElementById('examples').style.display='none';
\\  // remove any old suggestion chips
\\  document.querySelectorAll('.suggestions').forEach(el=>el.remove());
\\
\\  addMessage('user', formatText(q));
\\  const loadingDiv = addMessage('ai',
\\    '<span class="typing"><span class="dot"></span><span class="dot"></span><span class="dot"></span></span>');
\\
\\  // fire AI + suggestions concurrently
\\  const aiPromise = fetch('/api/ai',{
\\    method:'POST',
\\    headers:{'Content-Type':'application/json'},
\\    body:JSON.stringify({question:q})
\\  }).then(r=>r.json()).catch(e=>({error:e.message}));
\\
\\  const sugPromise = fetch('/api/suggestions',{
\\    method:'POST',
\\    headers:{'Content-Type':'application/json'},
\\    body:JSON.stringify({question:q})
\\  }).then(r=>r.json()).catch(()=>null);
\\
\\  const [data, sugData] = await Promise.all([aiPromise, sugPromise]);
\\
\\  if(data.error){
\\    const m = typeof data.error==='string'?data.error:(data.error.message||JSON.stringify(data.error));
\\    loadingDiv.querySelector('.msg-text').innerHTML='<span class="error">'+formatText(m)+'</span>';
\\  } else if(data.answer){
\\    loadingDiv.querySelector('.msg-text').innerHTML = formatText(data.answer);
\\  } else {
\\    loadingDiv.querySelector('.msg-text').innerHTML='<span class="error">Unexpected response</span>';
\\  }
\\
\\  loadingDiv.scrollIntoView({behavior:'smooth', block:'end'});
\\  isLoading=false;
\\  document.getElementById('send-btn').disabled=false;
\\  input.focus();
\\
\\  // append suggestions (already fetched concurrently)
\\  if(sugData && sugData.suggestions && sugData.suggestions.length){
\\    const wrap = document.createElement('div');
\\    wrap.className = 'suggestions';
\\    sugData.suggestions.forEach(s=>{
\\      const btn = document.createElement('button');
\\      btn.className = 'sug-btn';
\\      btn.textContent = s;
\\      btn.onclick = ()=>{
\\        document.querySelectorAll('.suggestions').forEach(el=>el.remove());
\\        sendMessage(s);
\\      };
\\      wrap.appendChild(btn);
\\    });
\\    chat.appendChild(wrap);
\\    wrap.scrollIntoView({behavior:'smooth', block:'end'});
\\  }
\\}
    \\</script>
;

const page_css =
    \\/* ── Layout ──────────────────────────────────────────────── */
    \\.ai-page {
    \\  display: flex;
    \\  flex-direction: column;
    \\  min-height: calc(100vh - 180px);
    \\}
    \\.ai-header { margin-bottom: 16px; }
    \\h1 { font-family:'DM Serif Display',Georgia,serif; font-size:32px; letter-spacing:-0.02em; margin-bottom:6px; }
    \\.red { color:var(--red); }
    \\.subtitle { font-size:13px; color:var(--muted); margin-bottom:20px; }
    \\
    \\/* ── Nav ──────────────────────────────────────────────────── */
    \\.sg-nav {
    \\  display:flex; gap:4px; margin-bottom:28px;
    \\  background:var(--bg2); border:1px solid var(--border);
    \\  border-radius:10px; padding:4px; flex-wrap:wrap;
    \\}
    \\.sg-nav-link {
    \\  flex:1; text-align:center; padding:8px 10px; font-size:13px;
    \\  color:var(--muted); border-radius:7px; transition:all 0.15s;
    \\  font-weight:500; white-space:nowrap; min-width:0;
    \\}
    \\.sg-nav-link:hover { color:var(--text); background:var(--bg3); }
    \\.sg-nav-link.active { background:var(--text); color:var(--bg); }
    \\
    \\/* ── Example chips ────────────────────────────────────────── */
    \\.examples { display:flex; flex-wrap:wrap; gap:8px; margin-bottom:20px; }
    \\.example-btn {
    \\  padding:9px 14px; background:var(--bg2);
    \\  border:1px solid var(--border); border-radius:20px;
    \\  font-size:13px; font-family:'DM Sans',sans-serif;
    \\  color:var(--text); cursor:pointer; transition:all 0.15s;
    \\  line-height:1.3;
    \\}
    \\.example-btn:hover { border-color:var(--red); background:var(--bg3); }
    \\
    \\/* ── Chat area ────────────────────────────────────────────── */
    \\.chat {
    \\  flex:1;
    \\  overflow-y:auto;
    \\  display:flex; flex-direction:column; gap:10px;
    \\  padding: 4px 0 8px;
    \\  min-height:80px;
    \\}
    \\.msg { padding:14px 18px; border-radius:12px; max-width:100%; word-break:break-word; }
    \\.msg-user {
    \\  background:var(--bg3); align-self:flex-end;
    \\  margin-left:clamp(20px,15%,80px); border-bottom-right-radius:4px;
    \\}
    \\.msg-ai {
    \\  background:var(--bg2); border:1px solid var(--border);
    \\  align-self:flex-start; margin-right:clamp(20px,10%,60px);
    \\  border-bottom-left-radius:4px;
    \\}
    \\.msg-role {
    \\  font-size:10px; color:var(--muted); text-transform:uppercase;
    \\  letter-spacing:0.07em; margin-bottom:5px; font-weight:700;
    \\}
    \\.msg-text { font-size:14px; line-height:1.75; }
    \\.msg-text code { font-family:'SF Mono',monospace; font-size:12px; background:var(--bg3); padding:1px 5px; border-radius:3px; }
    \\.msg-text strong { color:var(--red); }
    \\.error { color:var(--red); }
    \\
    \\/* ── Typing animation ─────────────────────────────────────── */
    \\.typing { display:inline-flex; gap:4px; align-items:center; padding:4px 0; }
    \\.dot {
    \\  width:6px; height:6px; background:var(--muted); border-radius:50%;
    \\  animation:bounce 1.2s infinite;
    \\}
    \\.dot:nth-child(2) { animation-delay:0.2s; }
    \\.dot:nth-child(3) { animation-delay:0.4s; }
    \\@keyframes bounce { 0%,60%,100%{transform:translateY(0)} 30%{transform:translateY(-6px)} }
    \\
    \\/* ── Follow-up suggestion chips ──────────────────────────── */
    \\.suggestions {
    \\  display:flex; flex-wrap:wrap; gap:8px;
    \\  padding:4px 0 8px; align-self:flex-start;
    \\  max-width:90%;
    \\}
    \\.sug-btn {
    \\  padding:8px 14px;
    \\  background:transparent;
    \\  border:1px solid var(--red);
    \\  border-radius:20px;
    \\  font-size:12px; font-family:'DM Sans',sans-serif;
    \\  color:var(--red); cursor:pointer;
    \\  transition:all 0.15s; line-height:1.3;
    \\  text-align:left;
    \\}
    \\.sug-btn:hover { background:var(--red); color:#fff; }
    \\
    \\/* ── Input bar ────────────────────────────────────────────── */
    \\.input-bar {
    \\  display:flex; gap:8px;
    \\  position:sticky; bottom:0;
    \\  background:var(--bg); padding:12px 0 8px;
    \\  border-top:1px solid var(--border);
    \\  margin-top:8px;
    \\}
    \\.chat-input {
    \\  flex:1; padding:13px 16px;
    \\  border:1px solid var(--border); border-radius:10px;
    \\  background:var(--bg2); font-size:14px;
    \\  font-family:'DM Sans',sans-serif; color:var(--text);
    \\  outline:none; min-width:0;
    \\}
    \\.chat-input:focus { border-color:var(--red); }
    \\.send-btn {
    \\  flex-shrink:0; width:46px; height:46px;
    \\  background:var(--red); color:#fff;
    \\  border:none; border-radius:10px; cursor:pointer;
    \\  display:flex; align-items:center; justify-content:center;
    \\  transition:opacity 0.15s;
    \\}
    \\.send-btn:hover { opacity:0.85; }
    \\.send-btn:disabled { opacity:0.45; cursor:not-allowed; }
    \\
    \\/* ── Footer ───────────────────────────────────────────────── */
    \\.footer-note { font-size:11px; color:var(--muted); text-align:center; padding:8px 0 4px; }
    \\.footer-note strong { color:var(--text); }
    \\.footer-note code { font-family:'SF Mono',monospace; font-size:10px; background:var(--bg3); padding:1px 4px; border-radius:3px; }
    \\
    \\/* ── Mobile ───────────────────────────────────────────────── */
    \\@media (max-width: 600px) {
    \\  .ai-page { min-height: calc(100vh - 140px); }
    \\  h1 { font-size:26px; }
    \\  .sg-nav { gap:3px; padding:3px; margin-bottom:20px; }
    \\  .sg-nav-link { font-size:11px; padding:7px 6px; }
    \\  .msg { padding:12px 14px; }
    \\  .msg-user { margin-left:12px; }
    \\  .msg-ai { margin-right:8px; }
    \\  .example-btn { font-size:12px; padding:8px 12px; }
    \\  .chat-input { font-size:16px; /* prevent zoom on iOS */ }
    \\}
;
