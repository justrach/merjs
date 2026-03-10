const mer = @import("mer");

pub const meta: mer.Meta = .{
    .title = "SG Data Explorer",
    .description = "Browse 1,300+ Singapore government datasets from data.gov.sg — search, filter, and explore public data.",
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
    \\  <a href="/explore" class="sg-nav-link active">Explore</a>
    \\  <a href="/ai" class="sg-nav-link">AI</a>
    \\</nav>
    \\
    \\<h1>Data <span class="red">Explorer</span></h1>
    \\<p class="subtitle">Browse 1,300+ open datasets from the Singapore government</p>
    \\
    \\<div class="search-bar">
    \\  <input type="text" class="search-input" id="search" placeholder="Search datasets... (e.g. population, housing, transport)" onkeydown="if(event.key==='Enter')doSearch()">
    \\  <button class="search-btn" onclick="doSearch()">Search</button>
    \\</div>
    \\
    \\<div class="filter-bar" id="filter-bar">
    \\  <button class="filter-btn active" data-page="1" onclick="loadPage(1)">Page 1</button>
    \\</div>
    \\
    \\<div class="results-meta" id="results-meta"></div>
    \\<div id="results" class="results">
    \\  <div class="loading">Loading collections&hellip;</div>
    \\</div>
    \\
    \\<div class="pagination" id="pagination"></div>
    \\
    \\<p class="footer-note">
    \\  Data from <a href="https://data.gov.sg">data.gov.sg</a> public API &middot;
    \\  served by <code>merjs</code>
    \\</p>
    \\
    \\<script>
    \\let currentPage = 1;
    \\let totalPages = 1;
    \\
    \\async function loadCollections(page){
    \\  currentPage = page;
    \\  document.getElementById('results').innerHTML = '<div class="loading">Loading&hellip;</div>';
    \\  try{
    \\    const res = await fetch('/api/collections?page='+page).then(r=>r.json());
    \\    if(res.error){
    \\      document.getElementById('results').innerHTML = '<div class="error-card"><p>'+res.error+'</p><p class="hint">Set <code>SG_DATA_API_KEY</code> environment variable to enable dataset browsing.</p></div>';
    \\      return;
    \\    }
    \\    const collections = res.collections || [];
    \\    totalPages = res.totalPages || 1;
    \\
    \\    document.getElementById('results-meta').textContent = 'Showing page '+page+' of '+totalPages;
    \\
    \\    let html = '';
    \\    for(const c of collections){
    \\      const updated = c.lastUpdatedAt ? new Date(c.lastUpdatedAt).toLocaleDateString('en-SG') : 'N/A';
    \\      const source = (c.sources && c.sources[0]) || c.managedByAgencyName || 'Unknown';
    \\      const freq = c.frequency || 'N/A';
    \\      const datasets = c.childDatasets ? c.childDatasets.length : 0;
    \\      html += '<div class="collection-card">'
    \\        +'<div class="cc-header">'
    \\        +'<div class="cc-id">#'+c.collectionId+'</div>'
    \\        +'<div class="cc-freq">'+freq+'</div>'
    \\        +'</div>'
    \\        +'<div class="cc-name">'+c.name+'</div>'
    \\        +'<div class="cc-desc">'+(c.description ? c.description.slice(0,200) : 'No description')+'</div>'
    \\        +'<div class="cc-footer">'
    \\        +'<span class="cc-source">'+source+'</span>'
    \\        +'<span class="cc-meta">'+datasets+' dataset'+(datasets!==1?'s':'')+' &middot; Updated '+updated+'</span>'
    \\        +'</div></div>';
    \\    }
    \\    document.getElementById('results').innerHTML = html || '<div class="no-data">No collections found</div>';
    \\
    \\    // Pagination
    \\    let pHtml = '';
    \\    const start = Math.max(1,page-2);
    \\    const end = Math.min(totalPages,page+2);
    \\    if(page>1) pHtml += '<button class="page-btn" onclick="loadCollections('+(page-1)+')">&laquo; Prev</button>';
    \\    for(let i=start;i<=end;i++){
    \\      pHtml += '<button class="page-btn'+(i===page?' active':'')+'" onclick="loadCollections('+i+')">'+i+'</button>';
    \\    }
    \\    if(page<totalPages) pHtml += '<button class="page-btn" onclick="loadCollections('+(page+1)+')">Next &raquo;</button>';
    \\    document.getElementById('pagination').innerHTML = pHtml;
    \\  }catch(e){
    \\    document.getElementById('results').innerHTML = '<div class="error-card">Failed to load: '+e.message+'</div>';
    \\  }
    \\}
    \\
    \\function doSearch(){
    \\  const q = document.getElementById('search').value.trim();
    \\  if(q){
    \\    loadSearch(q);
    \\  } else {
    \\    loadCollections(1);
    \\  }
    \\}
    \\
    \\async function loadSearch(query){
    \\  document.getElementById('results').innerHTML = '<div class="loading">Searching&hellip;</div>';
    \\  try{
    \\    const res = await fetch('/api/collections?search='+encodeURIComponent(query)).then(r=>r.json());
    \\    if(res.error){
    \\      document.getElementById('results').innerHTML = '<div class="error-card"><p>'+res.error+'</p></div>';
    \\      return;
    \\    }
    \\    const datasets = res.datasets || [];
    \\    document.getElementById('results-meta').textContent = datasets.length+' results for "'+query+'"';
    \\    let html = '';
    \\    for(const d of datasets){
    \\      const updated = d.lastUpdatedAt ? new Date(d.lastUpdatedAt).toLocaleDateString('en-SG') : 'N/A';
    \\      html += '<div class="collection-card">'
    \\        +'<div class="cc-header">'
    \\        +'<div class="cc-id">'+d.format+'</div>'
    \\        +'</div>'
    \\        +'<div class="cc-name">'+d.name+'</div>'
    \\        +'<div class="cc-desc">'+(d.description ? d.description.slice(0,200) : 'No description')+'</div>'
    \\        +'<div class="cc-footer">'
    \\        +'<span class="cc-source">'+(d.managedByAgencyName||'Unknown')+'</span>'
    \\        +'<span class="cc-meta">Updated '+updated+'</span>'
    \\        +'</div></div>';
    \\    }
    \\    document.getElementById('results').innerHTML = html || '<div class="no-data">No results for "'+query+'"</div>';
    \\    document.getElementById('pagination').innerHTML = '';
    \\  }catch(e){
    \\    document.getElementById('results').innerHTML = '<div class="error-card">Search failed: '+e.message+'</div>';
    \\  }
    \\}
    \\
    \\function loadPage(p){ loadCollections(p); }
    \\loadCollections(1);
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
    \\.card { background:var(--bg2); border:1px solid var(--border); border-radius:12px; padding:24px; margin-bottom:16px; }
    \\/* Search */
    \\.search-bar { display:flex; gap:8px; margin-bottom:20px; }
    \\.search-input { flex:1; padding:12px 16px; border:1px solid var(--border); border-radius:8px; background:var(--bg2); font-size:14px; font-family:'DM Sans',sans-serif; color:var(--text); outline:none; }
    \\.search-input:focus { border-color:var(--red); }
    \\.search-btn { padding:12px 24px; background:var(--red); color:#fff; border:none; border-radius:8px; font-size:13px; font-weight:600; font-family:'DM Sans',sans-serif; cursor:pointer; transition:opacity 0.15s; }
    \\.search-btn:hover { opacity:0.9; }
    \\/* Results */
    \\.results-meta { font-size:12px; color:var(--muted); margin-bottom:12px; }
    \\.results { display:flex; flex-direction:column; gap:10px; }
    \\.collection-card { background:var(--bg2); border:1px solid var(--border); border-radius:10px; padding:20px; transition:border-color 0.15s; }
    \\.collection-card:hover { border-color:var(--red); }
    \\.cc-header { display:flex; justify-content:space-between; align-items:center; margin-bottom:8px; }
    \\.cc-id { font-family:'SF Mono',monospace; font-size:11px; color:var(--muted); background:var(--bg3); padding:2px 8px; border-radius:4px; }
    \\.cc-freq { font-size:11px; color:var(--muted); text-transform:capitalize; }
    \\.cc-name { font-size:15px; font-weight:600; margin-bottom:6px; line-height:1.4; }
    \\.cc-desc { font-size:13px; color:var(--muted); line-height:1.5; margin-bottom:10px; }
    \\.cc-footer { display:flex; justify-content:space-between; align-items:center; }
    \\.cc-source { font-size:11px; color:var(--red); font-weight:500; }
    \\.cc-meta { font-size:11px; color:var(--muted); }
    \\/* Pagination */
    \\.pagination { display:flex; gap:4px; justify-content:center; margin-top:24px; }
    \\.page-btn { padding:8px 14px; background:var(--bg2); border:1px solid var(--border); border-radius:6px; font-size:12px; font-family:'DM Sans',sans-serif; color:var(--text); cursor:pointer; transition:all 0.15s; }
    \\.page-btn:hover { background:var(--bg3); }
    \\.page-btn.active { background:var(--text); color:var(--bg); border-color:var(--text); }
    \\/* Error */
    \\.error-card { background:var(--bg2); border:1px solid var(--red); border-radius:10px; padding:24px; text-align:center; color:var(--red); }
    \\.error-card .hint { color:var(--muted); font-size:12px; margin-top:8px; }
    \\.error-card code { font-family:'SF Mono',monospace; font-size:11px; background:var(--bg3); padding:1px 5px; border-radius:3px; }
    \\/* Filter */
    \\.filter-bar { display:flex; gap:4px; margin-bottom:16px; display:none; }
    \\.filter-btn { padding:6px 12px; background:var(--bg3); border:1px solid var(--border); border-radius:6px; font-size:11px; font-family:'DM Sans',sans-serif; color:var(--muted); cursor:pointer; }
    \\.filter-btn.active { background:var(--text); color:var(--bg); border-color:var(--text); }
    \\/* Misc */
    \\.no-data { text-align:center; padding:40px; color:var(--muted); font-size:14px; }
    \\.loading { text-align:center; padding:24px; color:var(--muted); font-size:13px; }
    \\.footer-note { font-size:12px; color:var(--muted); text-align:center; margin-top:24px; }
    \\.footer-note a { text-decoration:underline; text-underline-offset:2px; }
    \\.footer-note code { font-family:'SF Mono',monospace; font-size:11px; background:var(--bg3); padding:1px 5px; border-radius:3px; }
;

