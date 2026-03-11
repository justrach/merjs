const mer = @import("mer");

pub const meta: mer.Meta = .{
    .title = "Singapore Data",
    .description = "Real-time Singapore government data dashboard — weather, air quality, UV index, powered by data.gov.sg",
    .og_title = "Singapore Live Data — merjs",
    .og_description = "Real-time government data rendered by a Zig web framework. Zero Node.js.",
    .og_type = "website",
    .twitter_card = "summary_large_image",
    .extra_head = "<script src=\"https://cdn.jsdelivr.net/npm/chart.js@4/dist/chart.umd.min.js\"></script><style>" ++ page_css ++ "</style>",
};

pub fn render(req: mer.Request) mer.Response {
    _ = req;
    return mer.html(html);
}

const html =
    \\<nav class="sg-nav">
    \\  <a href="/" class="sg-nav-link active">Dashboard</a>
    \\  <a href="/weather" class="sg-nav-link">Weather</a>
    \\  <a href="/environment" class="sg-nav-link">Environment</a>
    \\  <a href="/explore" class="sg-nav-link">Explore</a>
    \\  <a href="/ai" class="sg-nav-link">AI</a>
    \\</nav>
    \\
    \\<div class="sg-hero">
    \\  <div class="sg-flag-bar"></div>
    \\  <h1>Singapore <span class="red">Live</span> Data</h1>
    \\  <p class="hero-sub">Real-time government data from <strong>data.gov.sg</strong> — rendered by Zig, zero Node.js</p>
    \\</div>
    \\
    \\<!-- Key metrics row -->
    \\<div class="grid3" id="metrics-row">
    \\  <div class="card metric-card">
    \\    <div class="card-label"><span class="dot dot-pulse"></span> Temperature</div>
    \\    <div class="metric-icon" id="weather-icon">&#9728;&#65039;</div>
    \\    <div class="metric-value red" id="temp-value">&mdash;</div>
    \\    <div class="metric-sub" id="temp-range">Loading&hellip;</div>
    \\  </div>
    \\  <div class="card metric-card">
    \\    <div class="card-label"><span class="dot dot-green"></span> Air Quality (PSI)</div>
    \\    <div class="metric-icon">&#127811;</div>
    \\    <div class="metric-value" id="psi-value">&mdash;</div>
    \\    <div class="metric-sub" id="psi-label">Loading&hellip;</div>
    \\  </div>
    \\  <div class="card metric-card">
    \\    <div class="card-label"><span class="dot dot-orange"></span> UV Index</div>
    \\    <div class="metric-icon">&#9728;&#65039;</div>
    \\    <div class="metric-value" id="uv-value">&mdash;</div>
    \\    <div class="metric-sub" id="uv-label">Loading&hellip;</div>
    \\  </div>
    \\</div>
    \\
    \\<!-- Regional forecast -->
    \\<div class="card">
    \\  <div class="card-label"><span class="dot dot-red"></span> 2-Hour Regional Forecast</div>
    \\  <div class="region-grid" id="region-grid">
    \\    <div class="region-card"><div class="region-name">North</div><div class="region-forecast" id="r-north">--</div></div>
    \\    <div class="region-card"><div class="region-name">South</div><div class="region-forecast" id="r-south">--</div></div>
    \\    <div class="region-card"><div class="region-name">East</div><div class="region-forecast" id="r-east">--</div></div>
    \\    <div class="region-card"><div class="region-name">West</div><div class="region-forecast" id="r-west">--</div></div>
    \\    <div class="region-card"><div class="region-name">Central</div><div class="region-forecast" id="r-central">--</div></div>
    \\  </div>
    \\  <div class="forecast-time" id="forecast-time"></div>
    \\</div>
    \\
    \\<!-- PSI breakdown -->
    \\<div class="card">
    \\  <div class="card-label"><span class="dot dot-green"></span> PSI Breakdown by Region</div>
    \\  <div class="psi-bars" id="psi-bars">
    \\    <div class="loading">Fetching air quality data&hellip;</div>
    \\  </div>
    \\</div>
    \\
    \\<!-- 4-day outlook -->
    \\<div class="card">
    \\  <div class="card-label"><span class="dot dot-red"></span> 4-Day Outlook</div>
    \\  <div id="outlook-grid" class="outlook-grid">
    \\    <div class="loading">Fetching forecast&hellip;</div>
    \\  </div>
    \\</div>
    \\
    \\<!-- UV hourly chart -->
    \\<div class="card">
    \\  <div class="card-label"><span class="dot dot-orange"></span> UV Index (Today)</div>
    \\  <div class="chart-wrap"><canvas id="uvChart"></canvas></div>
    \\</div>
    \\
    \\<!-- Feature cards -->
    \\<div class="grid3" style="margin-top:24px">
    \\  <a href="/weather" class="card feature-link">
    \\    <div class="feature-icon">&#127782;&#65039;</div>
    \\    <div class="feature-title">Weather</div>
    \\    <div class="feature-desc">Forecasts, station readings, area conditions</div>
    \\  </a>
    \\  <a href="/environment" class="card feature-link">
    \\    <div class="feature-icon">&#127811;</div>
    \\    <div class="feature-title">Environment</div>
    \\    <div class="feature-desc">PSI, PM2.5, rainfall, UV analysis</div>
    \\  </a>
    \\  <a href="/explore" class="card feature-link">
    \\    <div class="feature-icon">&#128202;</div>
    \\    <div class="feature-title">Explore</div>
    \\    <div class="feature-desc">Browse 1,300+ government datasets</div>
    \\  </a>
    \\</div>
    \\
    \\<p class="footer-note">
    \\  Data from <a href="https://data.gov.sg">data.gov.sg</a> &middot;
    \\  served by <code>merjs</code> &middot;
    \\  <a href="/ai">Ask AI about this data &rarr;</a>
    \\</p>
    \\
    \\<!-- How this works -->
    \\<div class="card" style="margin-top:24px;text-align:center">
    \\  <div class="card-label" style="justify-content:center"><span class="dot dot-red"></span> How this works</div>
    \\  <p style="font-size:14px;color:var(--muted);max-width:560px;margin:0 auto;line-height:1.7">
    \\    This page is <strong style="color:var(--text)">one Zig file</strong> &mdash;
    \\    <code style="font-family:'SF Mono',monospace;font-size:12px;background:var(--bg3);padding:1px 5px;border-radius:3px">app/sg.zig</code>.
    \\    Client-side JS fetches live data from Singapore&rsquo;s open APIs. The server proxies
    \\    authenticated requests via <code style="font-family:'SF Mono',monospace;font-size:12px;background:var(--bg3);padding:1px 5px;border-radius:3px">api/*.zig</code> routes &mdash;
    \\    API keys stay server-side.
    \\  </p>
    \\</div>
    \\
    \\<script>
    \\const API = 'https://api-open.data.gov.sg/v2/real-time/api';
    \\const FORECAST_ICON = {
    \\  'Fair':'\u2600\uFE0F','Fair (Day)':'\u2600\uFE0F','Fair (Night)':'\uD83C\uDF19',
    \\  'Fair and Warm':'\uD83C\uDF21\uFE0F','Partly Cloudy':'\u26C5','Partly Cloudy (Day)':'\u26C5',
    \\  'Partly Cloudy (Night)':'\uD83C\uDF19','Cloudy':'\u2601\uFE0F','Hazy':'\uD83C\uDF2B\uFE0F',
    \\  'Slightly Hazy':'\uD83C\uDF2B\uFE0F','Windy':'\uD83D\uDCA8','Mist':'\uD83C\uDF2B\uFE0F',
    \\  'Light Rain':'\uD83C\uDF26\uFE0F','Moderate Rain':'\uD83C\uDF27\uFE0F','Heavy Rain':'\u26C8\uFE0F',
    \\  'Passing Showers':'\uD83C\uDF26\uFE0F','Light Showers':'\uD83C\uDF26\uFE0F','Showers':'\uD83C\uDF27\uFE0F',
    \\  'Heavy Showers':'\u26C8\uFE0F','Thundery Showers':'\u26C8\uFE0F',
    \\  'Heavy Thundery Showers':'\u26C8\uFE0F','Heavy Thundery Showers with Gusty Winds':'\u26C8\uFE0F'
    \\};
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
    \\function uvLabel(v){
    \\  if(v<=2) return 'Low';
    \\  if(v<=5) return 'Moderate';
    \\  if(v<=7) return 'High';
    \\  if(v<=10) return 'Very High';
    \\  return 'Extreme';
    \\}
    \\function uvColor(v){
    \\  if(v<=2) return '#22c55e';
    \\  if(v<=5) return '#eab308';
    \\  if(v<=7) return '#f97316';
    \\  if(v<=10) return '#ef4444';
    \\  return '#7f1d1d';
    \\}
    \\
    \\const CACHE_TTL = 30*60*1000;
    \\async function safeFetch(url){
    \\  const key = 'sg_cache_'+url;
    \\  try{
    \\    const cached = localStorage.getItem(key);
    \\    if(cached){ const {ts,data}=JSON.parse(cached); if(Date.now()-ts<CACHE_TTL) return data; }
    \\  }catch(e){}
    \\  try{
    \\    const r = await fetch(url); const data = await r.json();
    \\    try{ localStorage.setItem(key, JSON.stringify({ts:Date.now(),data})); }catch(e){}
    \\    return data;
    \\  }catch(e){ console.warn('Fetch failed:', url, e.message); return null; }
    \\}
    \\async function loadDashboard(){
    \\  try{
    \\  const [forecastRes, twoHrRes, psiRes, uvRes, outlookRes] = await Promise.all([
    \\    safeFetch(API+'/twenty-four-hr-forecast'),
    \\    safeFetch(API+'/two-hr-forecast'),
    \\    safeFetch(API+'/psi'),
    \\    safeFetch(API+'/uv'),
    \\    safeFetch(API+'/four-day-outlook')
    \\  ]);
    \\  console.log('Fetches done:', {forecastRes:!!forecastRes, twoHrRes:!!twoHrRes, psiRes:!!psiRes, uvRes:!!uvRes, outlookRes:!!outlookRes});
    \\
    \\  // 24hr forecast - hero metrics
    \\  if(forecastRes && forecastRes.data && forecastRes.data.records && forecastRes.data.records.length){
    \\    const gen = forecastRes.data.records[0].general;
    \\    const icon = FORECAST_ICON[gen.forecast.text] || '\u2600\uFE0F';
    \\    document.getElementById('weather-icon').textContent = icon;
    \\    document.getElementById('temp-value').textContent = gen.temperature.high + '\u00B0C';
    \\    document.getElementById('temp-range').textContent =
    \\      gen.temperature.low+'\u00B0 \u2013 '+gen.temperature.high+'\u00B0 | '+gen.forecast.text;
    \\  } else { document.getElementById('temp-range').textContent = 'Weather data unavailable'; }
    \\  // 2hr regional forecast
  \\  const items = twoHrRes?.data?.items;
    \\  if(items && items.length){
    \\    const latest = items[items.length-1];
    \\    const regions = latest.forecasts || [];
    \\    const regionMap = {};
    \\    for(const f of regions){
    \\      const name = f.area.toLowerCase();
    \\      if(['ang mo kio','bishan','toa payoh','novena'].includes(name))
    \\        regionMap.central = regionMap.central || f.forecast;
    \\      else if(['woodlands','yishun','sembawang','mandai'].includes(name))
    \\        regionMap.north = regionMap.north || f.forecast;
    \\      else if(['jurong east','jurong west','bukit batok','clementi'].includes(name))
    \\        regionMap.west = regionMap.west || f.forecast;
    \\      else if(['tampines','bedok','pasir ris','changi'].includes(name))
    \\        regionMap.east = regionMap.east || f.forecast;
    \\      else if(['sentosa','bukit merah','queenstown'].includes(name))
    \\        regionMap.south = regionMap.south || f.forecast;
    \\    }
    \\    for(const r of ['north','south','east','west','central']){
    \\      const el = document.getElementById('r-'+r);
    \\      const fc = regionMap[r] || 'N/A';
    \\      el.textContent = fc;
    \\    }
    \\    const vp = latest.valid_period || {};
    \\    if(vp.start){
    \\      const s = new Date(vp.start).toLocaleTimeString('en-SG',{hour:'2-digit',minute:'2-digit'});
    \\      const e = new Date(vp.end).toLocaleTimeString('en-SG',{hour:'2-digit',minute:'2-digit'});
    \\      document.getElementById('forecast-time').textContent = 'Valid: '+s+' \u2013 '+e;
    \\    }
    \\  }
    \\
    \\  // PSI
  \\  if(psiRes?.data?.items && psiRes.data.items.length){
    \\    const readings = psiRes.data.items[0].readings;
    \\    const psi24 = readings.psi_twenty_four_hourly;
    \\    const national = Math.round((psi24.west+psi24.east+psi24.central+psi24.south+psi24.north)/5);
    \\    const psiEl = document.getElementById('psi-value');
    \\    psiEl.textContent = national;
    \\    psiEl.style.color = psiColor(national);
    \\    document.getElementById('psi-label').textContent = psiLabel(national);
    \\
    \\    // PSI bars
    \\    let barsHtml = '<div class="psi-grid">';
    \\    for(const region of ['north','south','east','west','central']){
    \\      const v = psi24[region];
    \\      const pct = Math.min(v/300*100,100);
    \\      barsHtml += '<div class="psi-row">'
    \\        +'<span class="psi-region">'+region.charAt(0).toUpperCase()+region.slice(1)+'</span>'
    \\        +'<div class="psi-bar-track"><div class="psi-bar-fill" style="width:'+pct+'%;background:'+psiColor(v)+'"></div></div>'
    \\        +'<span class="psi-val" style="color:'+psiColor(v)+'">'+v+'</span>'
    \\        +'</div>';
    \\    }
    \\    barsHtml += '</div>';
    \\    // PM2.5 sub-index
    \\    const pm25 = readings.pm25_sub_index;
    \\    if(pm25){
    \\      barsHtml += '<div class="card-label" style="margin-top:16px"><span class="dot dot-blue"></span> PM2.5 Sub-Index</div>';
    \\      barsHtml += '<div class="psi-grid">';
    \\      for(const region of ['north','south','east','west','central']){
    \\        const v = pm25[region];
    \\        const pct = Math.min(v/200*100,100);
    \\        barsHtml += '<div class="psi-row">'
    \\          +'<span class="psi-region">'+region.charAt(0).toUpperCase()+region.slice(1)+'</span>'
    \\          +'<div class="psi-bar-track"><div class="psi-bar-fill" style="width:'+pct+'%;background:'+psiColor(v)+'"></div></div>'
    \\          +'<span class="psi-val">'+v+'</span>'
    \\          +'</div>';
    \\      }
    \\      barsHtml += '</div>';
    \\    }
    \\    document.getElementById('psi-bars').innerHTML = barsHtml;
    \\  }
    \\
    \\  // UV
  \\  if(uvRes?.data?.records && uvRes.data.records.length){
    \\    const uvData = uvRes.data.records[0].index;
    \\    if(uvData && uvData.length){
    \\      const latest = uvData[0];
    \\      const uvEl = document.getElementById('uv-value');
    \\      uvEl.textContent = latest.value;
    \\      uvEl.style.color = uvColor(latest.value);
    \\      document.getElementById('uv-label').textContent = uvLabel(latest.value);
    \\
    \\      // UV chart
    \\      const labels = uvData.slice().reverse().map(function(d){
    \\        return new Date(d.hour).getHours()+':00';
    \\      });
    \\      const values = uvData.slice().reverse().map(function(d){ return d.value; });
    \\      const ctx = document.getElementById('uvChart').getContext('2d');
    \\      new Chart(ctx,{
    \\        type:'line',
    \\        data:{
    \\          labels:labels,
    \\          datasets:[{
    \\            label:'UV Index',
    \\            data:values,
    \\            borderColor:'#f97316',
    \\            backgroundColor:'rgba(249,115,22,0.1)',
    \\            fill:true,
    \\            tension:0.3,
    \\            pointRadius:3,
    \\            pointBackgroundColor:'#f97316'
    \\          }]
    \\        },
    \\        options:{
    \\          responsive:true,maintainAspectRatio:false,
    \\          plugins:{legend:{display:false}},
    \\          scales:{
    \\            x:{ticks:{color:'#8a7f78'},grid:{display:false}},
    \\            y:{min:0,max:14,ticks:{color:'#8a7f78'},grid:{color:'rgba(0,0,0,0.06)'}}
    \\          }
    \\        }
    \\      });
    \\    }
    \\  }
    \\
    \\  // 4-day outlook
    \\  if(outlookRes.data.records && outlookRes.data.records.length){
    \\    const days = ['Sun','Mon','Tue','Wed','Thu','Fri','Sat'];
    \\    const forecasts = outlookRes.data.records[0].forecasts;
    \\    let ohtml = '';
    \\    for(const f of forecasts){
    \\      const dt = new Date(f.timestamp);
    \\      const day = days[dt.getDay()];
    \\      const date = dt.getDate()+'/'+(dt.getMonth()+1);
    \\      const ficon = FORECAST_ICON[f.forecast.text] || '\u2600\uFE0F';
    \\      ohtml += '<div class="outlook-card">'
    \\        +'<div class="outlook-day">'+day+' '+date+'</div>'
    \\        +'<div class="outlook-icon">'+ficon+'</div>'
    \\        +'<div class="outlook-temp"><span class="red">'+f.temperature.high+'\u00B0</span> / '+f.temperature.low+'\u00B0</div>'
    \\        +'<div class="outlook-desc">'+f.forecast.summary+'</div>'
    \\        +'<div class="outlook-wind">'+f.wind.direction+' '+f.wind.speed.low+'-'+f.wind.speed.high+' km/h</div>'
    \\        +'</div>';
    \\    }
    \\    document.getElementById('outlook-grid').innerHTML = ohtml;
    \\  }
    \\
    \\  }catch(err){
    \\    console.error('Dashboard error:', err);
    \\    document.getElementById('metrics-row').innerHTML = '<div style="grid-column:1/-1;text-align:center;padding:20px;color:#e8251f">Error: '+err.message+'</div>';
    \\  }
    \\}
    \\
    \\loadDashboard();
    \\</script>
;

const page_css =
    \\/* SG nav */
    \\.sg-nav { display:flex; gap:4px; margin-bottom:32px; background:var(--bg2); border:1px solid var(--border); border-radius:10px; padding:4px; }
    \\.sg-nav-link { flex:1; text-align:center; padding:8px 12px; font-size:13px; color:var(--muted); border-radius:8px; transition:all 0.15s; font-weight:500; }
    \\.sg-nav-link:hover { color:var(--text); background:var(--bg3); }
    \\.sg-nav-link.active { background:var(--text); color:var(--bg); }
    \\/* Hero */
    \\.sg-hero { text-align:center; margin-bottom:32px; }
    \\.sg-flag-bar { width:60px; height:4px; background:var(--red); border-radius:2px; margin:0 auto 16px; }
    \\.sg-hero h1 { font-family:'DM Serif Display',Georgia,serif; font-size:36px; letter-spacing:-0.03em; margin-bottom:8px; }
    \\.red { color:var(--red); }
    \\.hero-sub { font-size:14px; color:var(--muted); }
    \\/* Cards */
    \\.card { background:var(--bg2); border:1px solid var(--border); border-radius:12px; padding:24px; margin-bottom:16px; }
    \\.card-label { display:flex; align-items:center; gap:8px; font-size:11px; color:var(--muted); text-transform:uppercase; letter-spacing:0.08em; margin-bottom:16px; }
    \\.dot { width:7px; height:7px; border-radius:50%; flex-shrink:0; }
    \\.dot-red { background:var(--red); }
    \\.dot-pulse { background:var(--red); animation:pulse 2s infinite; }
    \\.dot-green { background:#22c55e; }
    \\.dot-blue { background:#3b82f6; }
    \\.dot-orange { background:#f97316; }
    \\@keyframes pulse { 0%,100%{opacity:1} 50%{opacity:0.4} }
    \\/* Grid */
    \\.grid3 { display:grid; grid-template-columns:1fr 1fr 1fr; gap:12px; }
    \\/* Metric cards */
    \\.metric-card { text-align:center; }
    \\.metric-icon { font-size:36px; margin-bottom:8px; }
    \\.metric-value { font-family:'SF Mono','Fira Code',monospace; font-size:36px; font-weight:700; letter-spacing:-0.03em; }
    \\.metric-sub { font-size:12px; color:var(--muted); margin-top:4px; }
    \\/* Regions */
    \\.region-grid { display:grid; grid-template-columns:repeat(5,1fr); gap:8px; }
    \\.region-card { background:var(--bg3); border-radius:8px; padding:16px 12px; text-align:center; }
    \\.region-name { font-size:11px; color:var(--muted); text-transform:uppercase; letter-spacing:0.06em; margin-bottom:6px; }
    \\.region-forecast { font-size:13px; font-weight:500; }
    \\.forecast-time { font-size:11px; color:var(--muted); text-align:right; margin-top:8px; }
    \\/* PSI bars */
    \\.psi-grid { display:flex; flex-direction:column; gap:8px; }
    \\.psi-row { display:flex; align-items:center; gap:12px; }
    \\.psi-region { font-size:12px; color:var(--muted); width:60px; text-align:right; }
    \\.psi-bar-track { flex:1; height:8px; background:var(--bg3); border-radius:4px; overflow:hidden; }
    \\.psi-bar-fill { height:100%; border-radius:4px; transition:width 0.8s ease; }
    \\.psi-val { font-family:'SF Mono',monospace; font-size:13px; width:36px; }
    \\/* Outlook */
    \\.outlook-grid { display:grid; grid-template-columns:repeat(4,1fr); gap:10px; }
    \\.outlook-card { background:var(--bg3); border-radius:8px; padding:16px; text-align:center; }
    \\.outlook-day { font-size:12px; color:var(--muted); font-weight:500; }
    \\.outlook-icon { font-size:28px; margin:8px 0; }
    \\.outlook-temp { font-family:'SF Mono',monospace; font-size:14px; }
    \\.outlook-desc { font-size:11px; color:var(--muted); margin-top:4px; }
    \\.outlook-wind { font-size:10px; color:var(--muted); margin-top:2px; }
    \\/* Chart */
    \\.chart-wrap { position:relative; height:200px; }
    \\.chart-wrap canvas { width:100%!important; height:100%!important; }
    \\/* Feature links */
    \\.feature-link { text-decoration:none; transition:transform 0.15s, box-shadow 0.15s; cursor:pointer; text-align:center; }
    \\.feature-link:hover { transform:translateY(-2px); box-shadow:0 4px 16px rgba(0,0,0,0.06); }
    \\.feature-icon { font-size:28px; margin-bottom:8px; }
    \\.feature-title { font-family:'DM Serif Display',Georgia,serif; font-size:16px; margin-bottom:4px; }
    \\.feature-desc { font-size:12px; color:var(--muted); }
    \\/* Misc */
    \\.loading { text-align:center; padding:24px; color:var(--muted); font-size:13px; }
    \\.footer-note { font-size:12px; color:var(--muted); text-align:center; margin-top:24px; }
    \\.footer-note a { text-decoration:underline; text-underline-offset:2px; }
    \\.footer-note code { font-family:'SF Mono',monospace; font-size:11px; background:var(--bg3); padding:1px 5px; border-radius:3px; }
    \\@media(max-width:768px) {
    \\  .grid3 { grid-template-columns:1fr; }
    \\  .region-grid { grid-template-columns:repeat(3,1fr); }
    \\  .outlook-grid { grid-template-columns:1fr 1fr; }
    \\}
;
