const mer = @import("mer");

pub const meta: mer.Meta = .{
    .title = "SG Weather Map",
    .description = "Live Singapore weather on an interactive map — temperature, rainfall, and forecasts from NEA stations.",
    .extra_head = "<link rel=\"stylesheet\" href=\"https://unpkg.com/leaflet@1.9.4/dist/leaflet.css\">" ++
        "<script src=\"https://unpkg.com/leaflet@1.9.4/dist/leaflet.js\"></script>" ++
        "<script src=\"https://cdn.jsdelivr.net/npm/chart.js@4/dist/chart.umd.min.js\"></script>" ++
        "<style>" ++ page_css ++ "</style>",
};

pub fn render(req: mer.Request) mer.Response {
    _ = req;
    return mer.html(html);
}

const html =
    \\<nav class="sg-nav">
    \\  <a href="/" class="sg-nav-link">Dashboard</a>
    \\  <a href="/weather" class="sg-nav-link active">Weather</a>
    \\  <a href="/environment" class="sg-nav-link">Environment</a>
    \\  <a href="/explore" class="sg-nav-link">Explore</a>
    \\  <a href="/ai" class="sg-nav-link">AI</a>
    \\</nav>
    \\
    \\<h1>Singapore <span class="red">Weather Map</span></h1>
    \\<p class="subtitle">Live station readings plotted across the island &mdash; tap markers for details</p>
    \\
    \\<div class="card map-card">
    \\  <div class="map-controls">
    \\    <button class="map-btn active" onclick="setLayer('temp')" id="btn-temp"><span class="dot dot-red"></span> Temperature</button>
    \\    <button class="map-btn" onclick="setLayer('rain')" id="btn-rain"><span class="dot dot-blue"></span> Rainfall</button>
    \\    <button class="map-btn" onclick="setLayer('humidity')" id="btn-humidity"><span class="dot dot-teal"></span> Humidity</button>
    \\    <button class="map-btn" onclick="setLayer('forecast')" id="btn-forecast"><span class="dot dot-green"></span> Forecast</button>
    \\  </div>
    \\  <div id="map" style="height:480px;border-radius:8px;"></div>
    \\  <div class="map-legend" id="legend"></div>
    \\</div>
    \\
    \\<!-- National forecast -->
    \\<div class="card">
    \\  <div class="card-label"><span class="dot dot-pulse"></span> 24-Hour National Forecast</div>
    \\  <div class="national-grid" id="national">
    \\    <div class="loading">Loading forecast&hellip;</div>
    \\  </div>
    \\</div>
    \\
    \\<!-- 4-day outlook -->
    \\<div class="card">
    \\  <div class="card-label"><span class="dot dot-red"></span> 4-Day Outlook</div>
    \\  <div id="outlook" class="outlook-grid">
    \\    <div class="loading">Loading&hellip;</div>
    \\  </div>
    \\</div>
    \\
    \\<p class="footer-note">
    \\  Data from <a href="https://data.gov.sg">data.gov.sg</a> real-time APIs &middot;
    \\  served by <code>merjs</code>
    \\</p>
    \\
    \\<script>
    \\const API = 'https://api-open.data.gov.sg/v2/real-time/api';
    \\const ICON = {
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
    \\// Cached fetch — localStorage KV with 30min TTL
    \\const CACHE_TTL = 30*60*1000;
    \\async function cachedFetch(url){
    \\  const key = 'sg_cache_'+url;
    \\  const cached = localStorage.getItem(key);
    \\  if(cached){
    \\    const {ts,data} = JSON.parse(cached);
    \\    if(Date.now()-ts < CACHE_TTL) return data;
    \\  }
    \\  const res = await fetch(url);
    \\  if(!res.ok) throw new Error(res.status);
    \\  const data = await res.json();
    \\  try{ localStorage.setItem(key, JSON.stringify({ts:Date.now(),data})); }catch(e){}
    \\  return data;
    \\}
    \\
    \\// Map setup
    \\const map = L.map('map',{zoomControl:false,attributionControl:false}).setView([1.3521,103.8198],12);
    \\L.control.zoom({position:'topright'}).addTo(map);
    \\L.control.attribution({prefix:false,position:'bottomright'}).addAttribution('&copy; <a href="https://carto.com">CARTO</a>').addTo(map);
    \\L.tileLayer('https://{s}.basemaps.cartocdn.com/light_all/{z}/{x}/{y}{r}.png',{
    \\  maxZoom:19, subdomains:'abcd'
    \\}).addTo(map);
    \\
    \\let layers = {temp:[], rain:[], humidity:[], forecast:[]};
    \\let activeLayer = 'temp';
    \\let stationData = {};
    \\
    \\function tempColor(v){
    \\  if(v>=34) return '#dc2626';
    \\  if(v>=31) return '#ea580c';
    \\  if(v>=28) return '#f59e0b';
    \\  if(v>=25) return '#22c55e';
    \\  return '#3b82f6';
    \\}
    \\
    \\function rainColor(v){
    \\  if(v>=10) return '#1e40af';
    \\  if(v>=5) return '#2563eb';
    \\  if(v>=1) return '#3b82f6';
    \\  if(v>0) return '#93c5fd';
    \\  return '#cbd5e1';
    \\}
    \\
    \\function humidColor(v){
    \\  if(v>=90) return '#0d9488';
    \\  if(v>=75) return '#14b8a6';
    \\  if(v>=60) return '#5eead4';
    \\  return '#99f6e4';
    \\}
    \\
    \\function makeCircle(lat,lng,color,label,popup,size){
    \\  const r = size||14;
    \\  const d = r*2;
    \\  const div = L.divIcon({
    \\    html:'<div class="pin" style="width:'+d+'px;height:'+d+'px;background:'+color+';box-shadow:0 0 0 3px rgba(255,255,255,0.9),0 2px 8px rgba(0,0,0,0.2)"><span>'+label+'</span></div>',
    \\    className:'pin-icon',
    \\    iconSize:[d,d],
    \\    iconAnchor:[r,r]
    \\  });
    \\  const m = L.marker([lat,lng],{icon:div});
    \\  m.bindPopup('<div class="pin-popup">'+popup+'</div>');
    \\  return m;
    \\}
    \\
    \\function setLayer(name){
    \\  // Remove old
    \\  layers[activeLayer].forEach(m => map.removeLayer(m));
    \\  document.getElementById('btn-'+activeLayer).classList.remove('active');
    \\  // Add new
    \\  activeLayer = name;
    \\  layers[name].forEach(m => m.addTo(map));
    \\  document.getElementById('btn-'+name).classList.add('active');
    \\  updateLegend(name);
    \\}
    \\
    \\function updateLegend(layer){
    \\  const el = document.getElementById('legend');
    \\  if(layer==='temp'){
    \\    el.innerHTML = '<span style="background:#3b82f6"></span>&lt;25\u00B0C '
    \\      +'<span style="background:#22c55e"></span>25-28\u00B0C '
    \\      +'<span style="background:#f59e0b"></span>28-31\u00B0C '
    \\      +'<span style="background:#ea580c"></span>31-34\u00B0C '
    \\      +'<span style="background:#dc2626"></span>&gt;34\u00B0C';
    \\  } else if(layer==='rain'){
    \\    el.innerHTML = '<span style="background:#cbd5e1"></span>None '
    \\      +'<span style="background:#93c5fd"></span>&lt;1mm '
    \\      +'<span style="background:#3b82f6"></span>1-5mm '
    \\      +'<span style="background:#2563eb"></span>5-10mm '
    \\      +'<span style="background:#1e40af"></span>&gt;10mm';
    \\  } else if(layer==='humidity'){
    \\    el.innerHTML = '<span style="background:#99f6e4"></span>&lt;60% '
    \\      +'<span style="background:#5eead4"></span>60-75% '
    \\      +'<span style="background:#14b8a6"></span>75-90% '
    \\      +'<span style="background:#0d9488"></span>&gt;90%';
    \\  } else {
    \\    el.innerHTML = 'Tap an area to see forecast';
    \\  }
    \\}
    \\
    \\async function loadMap(){
    \\  const [tempRes, rainRes, humidRes, fcRes] = await Promise.all([
    \\    cachedFetch(API+'/air-temperature'),
    \\    cachedFetch(API+'/rainfall'),
    \\    cachedFetch(API+'/relative-humidity'),
    \\    cachedFetch(API+'/two-hr-forecast')
    \\  ]);
    \\
    \\  // Temperature markers
    \\  if(tempRes.data.readings && tempRes.data.readings.length){
    \\    const reading = tempRes.data.readings[0];
    \\    const stations = tempRes.data.stations;
    \\    for(const d of reading.data){
    \\      const s = stations.find(st=>st.id===d.stationId);
    \\      if(!s) continue;
    \\      const v = d.value;
    \\      const m = makeCircle(
    \\        s.location.latitude, s.location.longitude,
    \\        tempColor(v), v.toFixed(1)+'\u00B0',
    \\        '<b>'+s.name+'</b><br>'+v.toFixed(1)+'\u00B0C'
    \\      );
    \\      layers.temp.push(m);
    \\    }
    \\  }
    \\
    \\  // Rainfall markers
    \\  if(rainRes.data.readings && rainRes.data.readings.length){
    \\    const reading = rainRes.data.readings[0];
    \\    const stations = rainRes.data.stations;
    \\    for(const d of reading.data){
    \\      const s = stations.find(st=>st.id===d.stationId);
    \\      if(!s) continue;
    \\      const v = d.value;
    \\      const sz = v>0 ? Math.min(8+v*2, 20) : 6;
    \\      const m = makeCircle(
    \\        s.location.latitude, s.location.longitude,
    \\        rainColor(v), v>0?v.toFixed(1):'', 
    \\        '<b>'+s.name+'</b><br>'+(v>0?v.toFixed(1)+' mm':'No rain'),
    \\        sz
    \\      );
    \\      layers.rain.push(m);
    \\    }
    \\  }
    \\
    \\  // Humidity markers
    \\  if(humidRes.data.readings && humidRes.data.readings.length){
    \\    const reading = humidRes.data.readings[0];
    \\    const stations = humidRes.data.stations;
    \\    for(const d of reading.data){
    \\      const s = stations.find(st=>st.id===d.stationId);
    \\      if(!s) continue;
    \\      const v = d.value;
    \\      const m = makeCircle(
    \\        s.location.latitude, s.location.longitude,
    \\        humidColor(v), v+'%',
    \\        '<b>'+s.name+'</b><br>Humidity: '+v+'%'
    \\      );
    \\      layers.humidity.push(m);
    \\    }
    \\  }
    \\
    \\  // 2hr forecast markers — use area label_location from metadata
    \\  const items = fcRes.data.items;
    \\  if(items && items.length){
    \\    const latest = items[items.length-1];
    \\    const meta = fcRes.data.area_metadata || [];
    \\    for(const f of latest.forecasts){
    \\      const loc = meta.find(m=>m.name===f.area);
    \\      if(!loc) continue;
    \\      const lat = loc.label_location.latitude;
    \\      const lng = loc.label_location.longitude;
    \\      const icon = ICON[f.forecast]||'\u2600\uFE0F';
    \\      const div = L.divIcon({
    \\        html:'<div class="fc-marker">'+icon+'</div>',
    \\        className:'fc-icon',
    \\        iconSize:[28,28],
    \\        iconAnchor:[14,14]
    \\      });
    \\      const m = L.marker([lat,lng],{icon:div});
    \\      m.bindPopup('<b>'+f.area+'</b><br>'+f.forecast);
    \\      m.bindTooltip(f.area,{direction:'bottom',offset:[0,10],className:'fc-tooltip'});
    \\      layers.forecast.push(m);
    \\    }
    \\  }
    \\
    \\  // Show temperature by default
    \\  layers.temp.forEach(m => m.addTo(map));
    \\  updateLegend('temp');
    \\}
    \\
    \\async function loadCards(){
    \\  const [forecastRes, outlookRes] = await Promise.all([
    \\    cachedFetch(API+'/twenty-four-hr-forecast'),
    \\    cachedFetch(API+'/four-day-outlook')
    \\  ]);
    \\
    \\  // National forecast
    \\  const rec = forecastRes.data.records[0];
    \\  const gen = rec.general;
    \\  let natHtml = '<div class="nat-hero">'
    \\    +'<div class="nat-icon">'+(ICON[gen.forecast.text]||'\u2600\uFE0F')+'</div>'
    \\    +'<div><div class="nat-temp">'+gen.temperature.low+'\u00B0 \u2013 '+gen.temperature.high+'\u00B0C</div>'
    \\    +'<div class="nat-desc">'+gen.forecast.text+'</div>'
    \\    +'<div class="nat-detail">Humidity: '+gen.relativeHumidity.low+'-'+gen.relativeHumidity.high+'% | Wind: '+gen.wind.direction+' '+gen.wind.speed.low+'-'+gen.wind.speed.high+' km/h</div>'
    \\    +'</div></div>';
    \\  natHtml += '<div class="periods-grid">';
    \\  for(const p of rec.periods){
    \\    natHtml += '<div class="period-card">'
    \\      +'<div class="period-time">'+p.timePeriod.text+'</div>'
    \\      +'<div class="period-regions">';
    \\    for(const [r,v] of Object.entries(p.regions)){
    \\      natHtml += '<div class="period-region"><span class="period-rname">'+r+'</span>'
    \\        +'<span>'+(ICON[v.text]||'')+' '+v.text+'</span></div>';
    \\    }
    \\    natHtml += '</div></div>';
    \\  }
    \\  natHtml += '</div>';
    \\  document.getElementById('national').innerHTML = natHtml;
    \\
    \\  // 4-day outlook
    \\  const days = ['Sun','Mon','Tue','Wed','Thu','Fri','Sat'];
    \\  const forecasts = outlookRes.data.records[0].forecasts;
    \\  let outHtml = '';
    \\  for(const f of forecasts){
    \\    const dt = new Date(f.timestamp);
    \\    outHtml += '<div class="out-card">'
    \\      +'<div class="out-day">'+days[dt.getDay()]+' '+dt.getDate()+'/'+(dt.getMonth()+1)+'</div>'
    \\      +'<div class="out-icon">'+(ICON[f.forecast.text]||'\u2600\uFE0F')+'</div>'
    \\      +'<div class="out-temp"><span class="red">'+f.temperature.high+'\u00B0</span> / '+f.temperature.low+'\u00B0</div>'
    \\      +'<div class="out-desc">'+f.forecast.summary+'</div>'
    \\      +'</div>';
    \\  }
    \\  document.getElementById('outlook').innerHTML = outHtml;
    \\}
    \\
    \\loadMap();
    \\loadCards();
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
    \\.dot-blue { background:#3b82f6; }
    \\.dot-teal { background:#14b8a6; }
    \\.dot-green { background:#22c55e; }
    \\@keyframes pulse { 0%,100%{opacity:1} 50%{opacity:0.4} }
    \\/* Map */
    \\.map-card { padding:16px; overflow:hidden; }
    \\.map-controls { display:flex; gap:6px; margin-bottom:12px; flex-wrap:wrap; }
    \\.map-btn { display:flex; align-items:center; gap:6px; padding:7px 14px; border:1px solid var(--border); border-radius:8px; background:var(--bg3); font-size:12px; font-family:'DM Sans',sans-serif; color:var(--muted); cursor:pointer; transition:all 0.15s; font-weight:500; }
    \\.map-btn:hover { color:var(--text); border-color:var(--text); }
    \\.map-btn.active { background:var(--text); color:var(--bg); border-color:var(--text); }
    \\.map-btn.active .dot { background:#fff; }
    \\.map-legend { display:flex; align-items:center; gap:10px; margin-top:10px; font-size:11px; color:var(--muted); flex-wrap:wrap; }
    \\.map-legend span { display:inline-block; width:12px; height:12px; border-radius:50%; vertical-align:middle; margin-right:2px; }
    \\/* Pins */
    \\.pin-icon { background:none!important; border:none!important; }
    \\.pin { border-radius:50%; display:flex; align-items:center; justify-content:center; transition:transform 0.15s; cursor:pointer; }
    \\.pin:hover { transform:scale(1.25); z-index:999!important; }
    \\.pin span { font-size:10px; font-weight:700; color:#fff; text-shadow:0 1px 2px rgba(0,0,0,0.4); white-space:nowrap; pointer-events:none; }
    \\.pin-popup { font-family:'DM Sans',sans-serif; font-size:13px; line-height:1.5; }
    \\.pin-popup b { font-size:14px; }
    \\.leaflet-popup-content-wrapper { border-radius:10px!important; box-shadow:0 4px 20px rgba(0,0,0,0.15)!important; }
    \\.leaflet-popup-tip { box-shadow:0 4px 12px rgba(0,0,0,0.1)!important; }
    \\/* Forecast icons */
    \\.fc-icon { background:none!important; border:none!important; }
    \\.fc-marker { font-size:26px; text-align:center; filter:drop-shadow(0 2px 4px rgba(0,0,0,0.25)); cursor:pointer; transition:transform 0.15s; }
    \\.fc-marker:hover { transform:scale(1.3); }
    \\.fc-tooltip { font-size:10px!important; padding:3px 8px!important; border-radius:6px!important; font-family:'DM Sans',sans-serif!important; }
    \\/* Leaflet overrides */
    \\.leaflet-control-zoom a { width:32px!important; height:32px!important; line-height:32px!important; border-radius:8px!important; font-size:16px!important; background:var(--bg2)!important; color:var(--text)!important; border:1px solid var(--border)!important; }
    \\.leaflet-control-zoom { border:none!important; box-shadow:0 2px 8px rgba(0,0,0,0.1)!important; border-radius:10px!important; overflow:hidden; }
    \\.leaflet-control-attribution { font-size:10px!important; background:rgba(255,255,255,0.7)!important; border-radius:6px 0 0 0!important; padding:2px 8px!important; }
    \\/* National */
    \\.nat-hero { display:flex; align-items:center; gap:20px; margin-bottom:20px; }
    \\.nat-icon { font-size:48px; }
    \\.nat-temp { font-family:'SF Mono',monospace; font-size:28px; font-weight:700; }
    \\.nat-desc { font-size:14px; color:var(--muted); margin-top:2px; }
    \\.nat-detail { font-size:12px; color:var(--muted); margin-top:4px; }
    \\.periods-grid { display:grid; grid-template-columns:repeat(4,1fr); gap:8px; }
    \\.period-card { background:var(--bg3); border-radius:8px; padding:12px; }
    \\.period-time { font-size:11px; color:var(--muted); font-weight:500; margin-bottom:8px; }
    \\.period-regions { display:flex; flex-direction:column; gap:4px; }
    \\.period-region { display:flex; justify-content:space-between; font-size:11px; }
    \\.period-rname { color:var(--muted); text-transform:capitalize; }
    \\/* Outlook */
    \\.outlook-grid { display:grid; grid-template-columns:repeat(4,1fr); gap:10px; }
    \\.out-card { background:var(--bg3); border-radius:8px; padding:16px; text-align:center; }
    \\.out-day { font-size:12px; color:var(--muted); font-weight:500; }
    \\.out-icon { font-size:28px; margin:8px 0; }
    \\.out-temp { font-family:'SF Mono',monospace; font-size:14px; }
    \\.out-desc { font-size:11px; color:var(--muted); margin-top:4px; }
    \\/* Misc */
    \\.loading { text-align:center; padding:24px; color:var(--muted); font-size:13px; }
    \\.no-data { text-align:center; padding:40px; color:var(--muted); font-size:13px; }
    \\.footer-note { font-size:12px; color:var(--muted); text-align:center; margin-top:24px; }
    \\.footer-note a { text-decoration:underline; text-underline-offset:2px; }
    \\.footer-note code { font-family:'SF Mono',monospace; font-size:11px; background:var(--bg3); padding:1px 5px; border-radius:3px; }
    \\@media(max-width:768px) {
    \\  .periods-grid, .outlook-grid { grid-template-columns:1fr 1fr; }
    \\}
;
