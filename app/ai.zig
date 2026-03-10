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
    \\<nav class="sg-nav">
    \\  <a href="/" class="sg-nav-link">Dashboard</a>
    \\  <a href="/weather" class="sg-nav-link">Weather</a>
    \\  <a href="/environment" class="sg-nav-link">Environment</a>
    \\  <a href="/explore" class="sg-nav-link">Explore</a>
    \\  <a href="/ai" class="sg-nav-link active">AI</a>
    \\</nav>
    \\
    \\<h1>Budget <span class="red">2026</span> AI</h1>
    \\<p class="subtitle">Ask questions about Singapore's FY2026 Budget Statement &mdash; powered by gpt-5-nano + EmergentDB</p>
    \\
    \\<!-- Example questions -->
    \\<div class="examples" id="examples">
    \\  <button class="example-btn" onclick="askExample(this)">What are the key tax changes in Budget 2026?</button>
    \\  <button class="example-btn" onclick="askExample(this)">How much is allocated for healthcare?</button>
    \\  <button class="example-btn" onclick="askExample(this)">What support is there for businesses?</button>
    \\  <button class="example-btn" onclick="askExample(this)">What are the GST changes?</button>
    \\  <button class="example-btn" onclick="askExample(this)">What is the overall fiscal position?</button>
    \\</div>
    \\
    \\<!-- Chat messages -->
    \\<div class="chat" id="chat"></div>
    \\
    \\<!-- Input -->
    \\<div class="input-bar">
    \\  <input type="text" class="chat-input" id="input" placeholder="Ask about the FY2026 Budget..." onkeydown="if(event.key==='Enter'&&!event.shiftKey){event.preventDefault();sendMessage()}">
    \\  <button class="send-btn" id="send-btn" onclick="sendMessage()">
    \\    <svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><path d="M22 2L11 13M22 2l-7 20-4-9-9-4z"/></svg>
    \\  </button>
    \\</div>
    \\
    \\<p class="footer-note" style="margin-top:16px">
    \\  Powered by <strong>gpt-5-nano</strong> &middot;
    \\  Document chunks stored in <strong>EmergentDB</strong> &middot;
    \\  served by <code>merjs</code>
    \\</p>
    \\
    \\<script>
    \\const chat = document.getElementById('chat');
    \\const input = document.getElementById('input');
    \\let isLoading = false;
    \\
    \\function addMessage(role, text){
    \\  const div = document.createElement('div');
    \\  div.className = 'msg msg-'+role;
    \\  div.innerHTML = '<div class="msg-role">'+(role==='user'?'You':'AI')+'</div>'
    \\    +'<div class="msg-text">'+formatText(text)+'</div>';
    \\  chat.appendChild(div);
    \\  chat.scrollTop = chat.scrollHeight;
    \\  return div;
    \\}
    \\
    \\function formatText(text){
    \\  return text
    \\    .replace(/\*\*(.*?)\*\*/g, '<strong>$1</strong>')
    \\    .replace(/\*(.*?)\*/g, '<em>$1</em>')
    \\    .replace(/`(.*?)`/g, '<code>$1</code>')
    \\    .replace(/\n/g, '<br>');
    \\}
    \\
    \\function askExample(btn){
    \\  input.value = btn.textContent;
    \\  sendMessage();
    \\  document.getElementById('examples').style.display = 'none';
    \\}
    \\
    \\async function sendMessage(){
    \\  const q = input.value.trim();
    \\  if(!q || isLoading) return;
    \\
    \\  isLoading = true;
    \\  input.value = '';
    \\  document.getElementById('send-btn').disabled = true;
    \\  document.getElementById('examples').style.display = 'none';
    \\
    \\  addMessage('user', q);
    \\  const loadingDiv = addMessage('ai', '<span class="typing">Searching budget document...</span>');
    \\
    \\  try{
    \\    const res = await fetch('/api/ai', {
    \\      method: 'POST',
    \\      headers: {'Content-Type': 'application/json'},
    \\      body: JSON.stringify({question: q})
    \\    });
    \\    const raw = await res.text();
    \\    console.log('API status:', res.status, 'body:', raw);
    \\    let data;
    \\    try{ data = JSON.parse(raw); }catch(pe){
    \\      loadingDiv.querySelector('.msg-text').innerHTML = '<span class="error">Bad JSON (see console): '+raw.slice(0,300)+'</span>';
    \\      isLoading=false; document.getElementById('send-btn').disabled=false; input.focus(); return;
    \\    }
    \\    if(data.error){
    \\      const errMsg = typeof data.error === 'string' ? data.error : (data.error.message || JSON.stringify(data.error));
    \\      loadingDiv.querySelector('.msg-text').innerHTML = formatText(errMsg);
    \\    } else if(data.answer){
    \\      loadingDiv.querySelector('.msg-text').innerHTML = formatText(data.answer);
    \\    } else {
    \\      loadingDiv.querySelector('.msg-text').innerHTML = 'Unexpected: '+raw.slice(0,300);
    \\    }
    \\  }catch(e){
    \\    console.error('fetch error:', e);
    \\    loadingDiv.querySelector('.msg-text').innerHTML = '<span class="error">'+e.message+'</span>';
    \\  }
    \\
    \\  isLoading = false;
    \\  document.getElementById('send-btn').disabled = false;
    \\  input.focus();
    \\}
    \\</script>
;

const page_css =
    \\/* SG nav */
    \\.sg-nav { display:flex; gap:4px; margin-bottom:32px; background:var(--bg2); border:1px solid var(--border); border-radius:10px; padding:4px; }
    \\.sg-nav-link { flex:1; text-align:center; padding:8px 12px; font-size:13px; color:var(--muted); border-radius:8px; transition:all 0.15s; font-weight:500; }
    \\.sg-nav-link:hover { color:var(--text); background:var(--bg3); }
    \\.sg-nav-link.active { background:var(--text); color:var(--bg); }
    \\h1 { font-family:'DM Serif Display',Georgia,serif; font-size:32px; letter-spacing:-0.02em; margin-bottom:8px; }
    \\.red { color:var(--red); }
    \\.subtitle { font-size:14px; color:var(--muted); margin-bottom:24px; }
    \\/* Examples */
    \\.examples { display:flex; flex-wrap:wrap; gap:8px; margin-bottom:24px; }
    \\.example-btn { padding:10px 16px; background:var(--bg2); border:1px solid var(--border); border-radius:8px; font-size:13px; font-family:'DM Sans',sans-serif; color:var(--text); cursor:pointer; transition:all 0.15s; }
    \\.example-btn:hover { border-color:var(--red); background:var(--bg3); }
    \\/* Chat */
    \\.chat { min-height:200px; max-height:500px; overflow-y:auto; margin-bottom:16px; display:flex; flex-direction:column; gap:12px; }
    \\.msg { padding:16px; border-radius:10px; }
    \\.msg-user { background:var(--bg3); margin-left:40px; }
    \\.msg-ai { background:var(--bg2); border:1px solid var(--border); margin-right:40px; }
    \\.msg-role { font-size:11px; color:var(--muted); text-transform:uppercase; letter-spacing:0.06em; margin-bottom:6px; font-weight:600; }
    \\.msg-text { font-size:14px; line-height:1.7; }
    \\.msg-text code { font-family:'SF Mono',monospace; font-size:12px; background:var(--bg3); padding:1px 5px; border-radius:3px; }
    \\.msg-text strong { color:var(--red); }
    \\.typing { color:var(--muted); animation:pulse 1.5s infinite; }
    \\@keyframes pulse { 0%,100%{opacity:1} 50%{opacity:0.4} }
    \\.error { color:var(--red); }
    \\/* Input */
    \\.input-bar { display:flex; gap:8px; position:sticky; bottom:0; background:var(--bg); padding:8px 0; }
    \\.chat-input { flex:1; padding:14px 18px; border:1px solid var(--border); border-radius:10px; background:var(--bg2); font-size:14px; font-family:'DM Sans',sans-serif; color:var(--text); outline:none; }
    \\.chat-input:focus { border-color:var(--red); }
    \\.send-btn { width:48px; height:48px; background:var(--red); color:#fff; border:none; border-radius:10px; cursor:pointer; display:flex; align-items:center; justify-content:center; transition:opacity 0.15s; }
    \\.send-btn:hover { opacity:0.9; }
    \\.send-btn:disabled { opacity:0.5; cursor:not-allowed; }
    \\/* Footer */
    \\.footer-note { font-size:12px; color:var(--muted); text-align:center; }
    \\.footer-note a { text-decoration:underline; text-underline-offset:2px; }
    \\.footer-note strong { color:var(--text); }
    \\.footer-note code { font-family:'SF Mono',monospace; font-size:11px; background:var(--bg3); padding:1px 5px; border-radius:3px; }
;
