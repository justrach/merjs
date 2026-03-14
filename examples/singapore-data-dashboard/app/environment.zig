const mer = @import("mer");

pub const meta: mer.Meta = .{
    .title = "SG Environment",
    .description = "Singapore air quality, UV index, and rainfall data from NEA — PSI readings, PM2.5, and weather station reports.",
    .extra_head = "<script defer src=\"https://cdn.jsdelivr.net/npm/chart.js@4/dist/chart.umd.min.js\"></script><style>" ++ page_css ++ "</style>",
};

pub fn render(req: mer.Request) mer.Response {
    _ = req;
    return mer.html(html);
}

const html =
    \\<nav class="sg-nav">
    \\  <a href="/" class="sg-nav-link">Dashboard</a>
    \\  <a href="/weather" class="sg-nav-link">Weather</a>
    \\  <a href="/environment" class="sg-nav-link active">Environment</a>
    \\</nav>
    \\
    \\<h1>Singapore <span class="red">Environment</span></h1>
    \\<p class="subtitle">Air quality, UV exposure, and rainfall &mdash; live from NEA stations</p>
    \\
    \\<!-- PSI Overview -->
    \\<div class="card">
    \\  <div class="card-label"><span class="dot dot-pulse"></span> Pollutant Standards Index (PSI)</div>
    \\  <div class="psi-hero" id="psi-hero">
    \\    <div class="loading">Fetching air quality data&hellip;</div>
    \\  </div>
    \\</div>
    \\
    \\<!-- PSI sub-indices -->
    \\<div class="card">
    \\  <div class="card-label"><span class="dot dot-green"></span> Sub-Indices Breakdown</div>
    \\  <div id="sub-indices">
    \\    <div class="loading">Loading&hellip;</div>
    \\  </div>
    \\</div>
    \\
    \\<!-- UV Index -->
    \\<div class="card">
    \\  <div class="card-label"><span class="dot dot-orange"></span> UV Index &mdash; Hourly</div>
    \\  <div class="uv-hero" id="uv-hero"></div>
    \\  <div class="chart-wrap"><canvas id="uvChart"></canvas></div>
    \\  <div class="uv-scale">
    \\    <span class="uv-s" style="background:#22c55e">0-2 Low</span>
    \\    <span class="uv-s" style="background:#eab308;color:#000">3-5 Moderate</span>
    \\    <span class="uv-s" style="background:#f97316">6-7 High</span>
    \\    <span class="uv-s" style="background:#ef4444">8-10 Very High</span>
    \\    <span class="uv-s" style="background:#7f1d1d">11+ Extreme</span>
    \\  </div>
    \\</div>
    \\
    \\<!-- Rainfall -->
    \\<div class="card">
    \\  <div class="card-label"><span class="dot dot-blue"></span> Rainfall by Station</div>
    \\  <div class="chart-wrap" style="height:300px"><canvas id="rainChart"></canvas></div>
    \\  <div class="rain-summary" id="rain-summary"></div>
    \\</div>
    \\
    \\<!-- Wind -->
    \\<div class="card">
    \\  <div class="card-label"><span class="dot dot-muted"></span> Wind Direction by Station</div>
    \\  <div class="wind-grid" id="wind-grid">
    \\    <div class="loading">Loading wind data&hellip;</div>
    \\  </div>
    \\</div>
    \\
    \\<p class="footer-note">
    \\  Data from <a href="https://data.gov.sg">data.gov.sg</a> &middot;
    \\  All readings are real-time from NEA weather stations &middot;
    \\  served by <code>merjs</code>
    \\</p>
    \\
    \\<script>
    \\const API = 'https://api-open.data.gov.sg/v2/real-time/api';
    \\const chartFont = {family:"'DM Sans',system-ui,sans-serif"};
    \\
    \\const CACHE_VER = 'v3';
    \\const CACHE_TTL = 30*60*1000;
    \\async function cachedFetch(url){
    \\  const key = 'sg_'+CACHE_VER+'_'+url;
    \\  try{
    \\    const cached = localStorage.getItem(key);
    \\    if(cached){ const {ts,data}=JSON.parse(cached); if(Date.now()-ts<CACHE_TTL) return data; }
    \\  }catch(e){}
    \\  const res = await fetch(url);
    \\  if(res.status===429){ console.warn('Rate limited:', url); return null; }
    \\  if(!res.ok) throw new Error(res.status);
    \\  const data = await res.json();
    \\  try{ localStorage.setItem(key, JSON.stringify({ts:Date.now(),data})); }catch(e){}
    \\  return data;
    \\}
    \\
    \\function psiColor(v){
    \\  if(v<=50) return '#22c55e';
    \\  if(v<=100) return '#eab308';
    \\  if(v<=200) return '#f97316';
    \\  if(v<=300) return '#ef4444';
    \\  return '#7f1d1d';
    \\}
    \\function psiLabel(v){
    \\  if(v<=50) return 'Good';
    \\  if(v<=100) return 'Moderate';
    \\  if(v<=200) return 'Unhealthy';
    \\  if(v<=300) return 'Very Unhealthy';
    \\  return 'Hazardous';
    \\}
    \\function psiDesc(v){
    \\  if(v<=50) return 'No health impact expected';
    \\  if(v<=100) return 'Few may notice sensitivity';
    \\  if(v<=200) return 'Sensitive groups should reduce outdoor activity';
    \\  if(v<=300) return 'Everyone should limit outdoor activity';
    \\  return 'Everyone should avoid outdoor activity';
    \\}
    \\function uvColor(v){
    \\  if(v<=2) return '#22c55e';
    \\  if(v<=5) return '#eab308';
    \\  if(v<=7) return '#f97316';
    \\  if(v<=10) return '#ef4444';
    \\  return '#7f1d1d';
    \\}
    \\
    \\function psiBar(label, regions, max){
    \\  let html = '<div class="sub-label">'+label+'</div><div class="sub-bars">';
    \\  for(const r of ['north','south','east','west','central']){
    \\    const v = regions[r];
    \\    const pct = Math.min(v/max*100,100);
    \\    html += '<div class="sub-row">'
    \\      +'<span class="sub-rname">'+r.charAt(0).toUpperCase()+r.slice(1)+'</span>'
    \\      +'<div class="sub-track"><div class="sub-fill" style="width:'+pct+'%;background:'+psiColor(v)+'"></div></div>'
    \\      +'<span class="sub-val">'+v+'</span></div>';
    \\  }
    \\  return html+'</div>';
    \\}
    \\
    \\async function loadEnv(){
    \\  try{
    \\  const [psiRes, uvRes, rainRes, windRes] = await Promise.all([
    \\    cachedFetch(API+'/psi'),
    \\    cachedFetch(API+'/uv'),
    \\    cachedFetch(API+'/rainfall'),
    \\    cachedFetch(API+'/wind-direction')
    \\  ]);
    \\
    \\  // PSI hero
    \\  if(psiRes?.data?.items && psiRes.data.items.length){
    \\    const r = psiRes.data.items[0].readings;
    \\    const psi = r.psi_twenty_four_hourly;
    \\    let html = '<div class="psi-gauges">';
    \\    for(const region of ['north','south','east','west','central']){
    \\      const v = psi[region];
    \\      html += '<div class="psi-gauge">'
    \\        +'<div class="psi-circle" style="border-color:'+psiColor(v)+'">'
    \\        +'<span class="psi-num" style="color:'+psiColor(v)+'">'+v+'</span></div>'
    \\        +'<div class="psi-rname">'+region.charAt(0).toUpperCase()+region.slice(1)+'</div>'
    \\        +'<div class="psi-rlabel" style="color:'+psiColor(v)+'">'+psiLabel(v)+'</div>'
    \\        +'</div>';
    \\    }
    \\    html += '</div>';
    \\    const national = Math.round(Object.values(psi).reduce(function(a,b){return a+b},0)/5);
    \\    html += '<div class="psi-national">'
    \\      +'<span>National average: <strong style="color:'+psiColor(national)+'">'+national+' \u2014 '+psiLabel(national)+'</strong></span>'
    \\      +'<span class="psi-advice">'+psiDesc(national)+'</span></div>';
    \\    document.getElementById('psi-hero').innerHTML = html;
    \\
    \\    // Sub-indices
    \\    let subHtml = '';
    \\    if(r.pm25_sub_index) subHtml += psiBar('PM2.5 Sub-Index', r.pm25_sub_index, 200);
    \\    if(r.pm10_sub_index) subHtml += psiBar('PM10 Sub-Index', r.pm10_sub_index, 200);
    \\    if(r.o3_sub_index) subHtml += psiBar('O\u2083 Sub-Index', r.o3_sub_index, 200);
    \\    if(r.no2_one_hour_max) subHtml += psiBar('NO\u2082 (1hr max)', r.no2_one_hour_max, 200);
    \\    if(r.so2_sub_index) subHtml += psiBar('SO\u2082 Sub-Index', r.so2_sub_index, 200);
    \\    if(r.co_sub_index) subHtml += psiBar('CO Sub-Index', r.co_sub_index, 200);
    \\    document.getElementById('sub-indices').innerHTML = subHtml || '<div class="no-data">No sub-index data available</div>';
    \\  }
    \\
    \\  // UV
    \\  if(uvRes?.data?.records && uvRes.data.records.length){
    \\    const uvData = uvRes.data.records[0].index;
    \\    if(uvData && uvData.length){
    \\      const current = uvData[0];
    \\      document.getElementById('uv-hero').innerHTML =
    \\        '<div class="uv-current">'
    \\        +'<div class="uv-big" style="color:'+uvColor(current.value)+'">'+current.value+'</div>'
    \\        +'<div class="uv-info"><div class="uv-time">As of '+new Date(current.hour).toLocaleTimeString('en-SG',{hour:'2-digit',minute:'2-digit'})+'</div></div>'
    \\        +'</div>';
    \\
    \\      const reversed = uvData.slice().reverse();
    \\      const labels = reversed.map(function(d){ return new Date(d.hour).getHours()+':00'; });
    \\      const values = reversed.map(function(d){ return d.value; });
    \\      const colors = reversed.map(function(d){ return uvColor(d.value); });
    \\      new Chart(document.getElementById('uvChart'),{
    \\        type:'bar',
    \\        data:{labels:labels, datasets:[{label:'UV Index',data:values,backgroundColor:colors,borderRadius:4}]},
    \\        options:{responsive:true,maintainAspectRatio:false,
    \\          plugins:{legend:{display:false}},
    \\          scales:{x:{ticks:{color:'#8a7f78'},grid:{display:false}},
    \\            y:{min:0,max:14,ticks:{color:'#8a7f78'},grid:{color:'rgba(0,0,0,0.06)'}}}}
    \\      });
    \\    }
    \\  }
    \\
    \\  // Rainfall
    \\  if(rainRes?.data?.readings && rainRes.data.readings.length){
    \\    const reading = rainRes.data.readings[0];
    \\    const stations = rainRes.data.stations;
    \\    const all = reading.data;
    \\    const raining = all.filter(function(d){ return d.value > 0; });
    \\    const sorted = raining.sort(function(a,b){ return b.value-a.value; }).slice(0,25);
    \\
    \\    if(sorted.length){
    \\      const labels = sorted.map(function(d){
    \\        const s = stations.find(function(st){ return st.id===d.stationId; });
    \\        return s ? s.name.split(' ').slice(0,3).join(' ') : d.stationId;
    \\      });
    \\      new Chart(document.getElementById('rainChart'),{
    \\        type:'bar',
    \\        data:{labels:labels, datasets:[{label:'Rainfall mm',data:sorted.map(function(d){return d.value}),
    \\          backgroundColor:'rgba(59,130,246,0.6)',borderRadius:4}]},
    \\        options:{responsive:true,maintainAspectRatio:false,indexAxis:'y',
    \\          plugins:{legend:{display:false}},
    \\          scales:{y:{ticks:{color:'#8a7f78'},grid:{display:false}},
    \\            x:{ticks:{color:'#8a7f78',callback:function(v){return v+'mm'}},grid:{color:'rgba(0,0,0,0.06)'}}}}
    \\      });
    \\      document.getElementById('rain-summary').textContent =
    \\        raining.length+' of '+all.length+' stations reporting rainfall. Highest: '+sorted[0].value+'mm';
    \\    } else {
    \\      document.getElementById('rainChart').parentElement.innerHTML =
    \\        '<div class="no-data">\u2600\uFE0F No rainfall detected across '+all.length+' stations</div>';
    \\      document.getElementById('rain-summary').textContent = 'All clear \u2014 no rain across Singapore right now.';
    \\    }
    \\  }
    \\
    \\  // Wind
    \\  if(windRes?.data?.readings && windRes.data.readings.length){
    \\    const reading = windRes.data.readings[0];
    \\    const stations = windRes.data.stations;
    \\    const data = reading.data.slice(0,12);
    \\    let wHtml = '';
    \\    for(const d of data){
    \\      const s = stations.find(function(st){ return st.id===d.stationId; });
    \\      const name = s ? s.name : d.stationId;
    \\      const deg = d.value;
    \\      const dir = ['N','NNE','NE','ENE','E','ESE','SE','SSE','S','SSW','SW','WSW','W','WNW','NW','NNW'];
    \\      const compass = dir[Math.round(deg/22.5)%16];
    \\      wHtml += '<div class="wind-card">'
    \\        +'<div class="wind-arrow" style="transform:rotate('+deg+'deg)">\u2191</div>'
    \\        +'<div class="wind-name">'+name.split(' ').slice(0,2).join(' ')+'</div>'
    \\        +'<div class="wind-dir">'+compass+' ('+Math.round(deg)+'\u00B0)</div>'
    \\        +'</div>';
    \\    }
    \\    document.getElementById('wind-grid').innerHTML = wHtml;
    \\  }
    \\
    \\  }catch(err){
    \\    console.error('Environment error:', err);
    \\    document.getElementById('psi-hero').innerHTML = '<div style="text-align:center;padding:20px;color:#e8251f">Error: '+err.message+'</div>';
    \\  }
    \\}
    \\
    \\loadEnv();
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
    \\.subtitle { font-size:14px; color:var(--muted); margin-bottom:32px; }
    \\.card { background:var(--bg2); border:1px solid var(--border); border-radius:12px; padding:24px; margin-bottom:16px; }
    \\.card-label { display:flex; align-items:center; gap:8px; font-size:11px; color:var(--muted); text-transform:uppercase; letter-spacing:0.08em; margin-bottom:16px; }
    \\.dot { width:7px; height:7px; border-radius:50%; flex-shrink:0; }
    \\.dot-red { background:var(--red); }
    \\.dot-pulse { background:var(--red); animation:pulse 2s infinite; }
    \\.dot-green { background:#22c55e; }
    \\.dot-blue { background:#3b82f6; }
    \\.dot-orange { background:#f97316; }
    \\.dot-muted { background:var(--muted); }
    \\@keyframes pulse { 0%,100%{opacity:1} 50%{opacity:0.4} }
    \\/* PSI gauges */
    \\.psi-gauges { display:flex; justify-content:space-around; gap:12px; margin-bottom:20px; }
    \\.psi-gauge { text-align:center; }
    \\.psi-circle { width:72px; height:72px; border-radius:50%; border:3px solid; display:flex; align-items:center; justify-content:center; margin:0 auto 8px; }
    \\.psi-num { font-family:'SF Mono',monospace; font-size:22px; font-weight:700; }
    \\.psi-rname { font-size:12px; font-weight:500; }
    \\.psi-rlabel { font-size:11px; }
    \\.psi-national { text-align:center; padding:12px; background:var(--bg3); border-radius:8px; font-size:13px; }
    \\.psi-advice { display:block; font-size:11px; color:var(--muted); margin-top:4px; }
    \\/* Sub indices */
    \\.sub-label { font-size:12px; font-weight:600; margin:16px 0 8px; }
    \\.sub-bars { display:flex; flex-direction:column; gap:6px; }
    \\.sub-row { display:flex; align-items:center; gap:10px; }
    \\.sub-rname { font-size:11px; color:var(--muted); width:55px; text-align:right; }
    \\.sub-track { flex:1; height:6px; background:var(--bg3); border-radius:3px; overflow:hidden; }
    \\.sub-fill { height:100%; border-radius:3px; transition:width 0.3s; }
    \\.sub-val { font-family:'SF Mono',monospace; font-size:11px; width:32px; }
    \\/* UV */
    \\.uv-hero { margin-bottom:16px; }
    \\.uv-current { display:flex; align-items:center; gap:16px; }
    \\.uv-big { font-family:'SF Mono',monospace; font-size:48px; font-weight:700; }
    \\.uv-info { font-size:13px; color:var(--muted); }
    \\.uv-time { font-size:11px; }
    \\.uv-scale { display:flex; gap:6px; margin-top:12px; flex-wrap:wrap; }
    \\.uv-s { font-size:10px; padding:3px 8px; border-radius:4px; color:#fff; }
    \\.chart-wrap { position:relative; height:200px; }
    \\/* Rain */
    \\.rain-summary { font-size:12px; color:var(--muted); margin-top:8px; text-align:center; }
    \\/* Wind */
    \\.wind-grid { display:grid; grid-template-columns:repeat(auto-fill,minmax(100px,1fr)); gap:12px; }
    \\.wind-card { text-align:center; padding:12px; background:var(--bg3); border-radius:8px; }
    \\.wind-arrow { font-size:28px; line-height:1; }
    \\.wind-name { font-size:11px; margin-top:4px; white-space:nowrap; overflow:hidden; text-overflow:ellipsis; }
    \\.wind-dir { font-size:10px; color:var(--muted); }
    \\/* Misc */
    \\.loading { text-align:center; color:var(--muted); padding:20px; font-size:13px; }
    \\.no-data { text-align:center; color:var(--muted); padding:16px; font-size:13px; }
    \\.footer-note { font-size:11px; color:var(--muted); text-align:center; margin-top:32px; }
;
