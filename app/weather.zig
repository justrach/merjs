const mer = @import("mer");

pub const meta: mer.Meta = .{
    .title = "Weather",
    .description = "Live weather dashboard powered by Open-Meteo. Temperature, precipitation, wind, and 7-day forecast.",
    .og_title = "merjs Weather \u{2014} Live Global Forecasts",
    .og_description = "Real-time weather data rendered by a Zig web framework with zero Node.js.",
    .og_type = "website",
    .twitter_card = "summary_large_image",
    .extra_head = "<script src=\"https://cdn.jsdelivr.net/npm/chart.js@4/dist/chart.umd.min.js\"></script><style>" ++ page_css ++ "</style>",
};

pub fn render(req: mer.Request) mer.Response {
    _ = req;
    return mer.html(html);
}

const html =
    \\<h1>Weather</h1>
    \\  <p class="subtitle">Live data from Open-Meteo &mdash; rendered client-side, fetched from a free API, charted with Chart.js</p>
    \\
    \\  <div class="location-bar" id="locations">
    \\    <button class="loc-btn active" data-lat="1.29" data-lon="103.85">Singapore</button>
    \\    <button class="loc-btn" data-lat="35.68" data-lon="139.69">Tokyo</button>
    \\    <button class="loc-btn" data-lat="40.71" data-lon="-74.01">New York</button>
    \\    <button class="loc-btn" data-lat="51.51" data-lon="-0.13">London</button>
    \\    <button class="loc-btn" data-lat="-33.87" data-lon="151.21">Sydney</button>
    \\  </div>
    \\
    \\  <!-- Current conditions -->
    \\  <div class="card" id="current-card">
    \\    <div class="card-label"><span class="dot dot-pulse"></span> Current conditions</div>
    \\    <div class="loading" id="current-loading">Fetching weather data&hellip;</div>
    \\    <div id="current-data" style="display:none">
    \\      <div class="grid4">
    \\        <div class="stat" style="grid-column:1/3">
    \\          <div class="stat-label">temperature</div>
    \\          <div style="display:flex;align-items:center;gap:16px">
    \\            <div class="weather-icon" id="weather-icon"></div>
    \\            <div class="stat-value huge red" id="cur-temp">&mdash;</div>
    \\          </div>
    \\        </div>
    \\        <div class="stat">
    \\          <div class="stat-label">feels like</div>
    \\          <div class="stat-value big" id="cur-feels">&mdash;</div>
    \\        </div>
    \\        <div class="stat">
    \\          <div class="stat-label">wind</div>
    \\          <div class="stat-value big" id="cur-wind">&mdash;</div>
    \\        </div>
    \\      </div>
    \\      <div class="grid4" style="margin-top:12px">
    \\        <div class="stat">
    \\          <div class="stat-label">humidity</div>
    \\          <div class="stat-value" id="cur-humidity">&mdash;</div>
    \\        </div>
    \\        <div class="stat">
    \\          <div class="stat-label">pressure</div>
    \\          <div class="stat-value" id="cur-pressure">&mdash;</div>
    \\        </div>
    \\        <div class="stat">
    \\          <div class="stat-label">cloud cover</div>
    \\          <div class="stat-value" id="cur-cloud">&mdash;</div>
    \\        </div>
    \\        <div class="stat">
    \\          <div class="stat-label">condition</div>
    \\          <div class="stat-value" id="cur-condition">&mdash;</div>
    \\        </div>
    \\      </div>
    \\    </div>
    \\  </div>
    \\
    \\  <!-- Temperature chart -->
    \\  <div class="card">
    \\    <div class="card-label"><span class="dot dot-red"></span> 24-hour temperature</div>
    \\    <div class="chart-wrap"><canvas id="tempChart"></canvas></div>
    \\  </div>
    \\
    \\  <!-- Precipitation chart -->
    \\  <div class="card">
    \\    <div class="card-label"><span class="dot dot-blue"></span> Precipitation probability</div>
    \\    <div class="chart-wrap"><canvas id="precipChart"></canvas></div>
    \\  </div>
    \\
    \\  <!-- Wind chart -->
    \\  <div class="card">
    \\    <div class="card-label"><span class="dot dot-green"></span> Wind speed</div>
    \\    <div class="chart-wrap"><canvas id="windChart"></canvas></div>
    \\  </div>
    \\
    \\  <!-- 7-day forecast -->
    \\  <div class="card">
    \\    <div class="card-label"><span class="dot dot-red"></span> 7-day forecast</div>
    \\    <div id="forecast-grid" class="loading">Loading&hellip;</div>
    \\  </div>
    \\
    \\  <p class="footer-note">
    \\    Powered by <a href="https://open-meteo.com/">Open-Meteo</a> &middot;
    \\    charts via <a href="https://www.chartjs.org/">Chart.js</a> &middot;
    \\    served by <code>merjs</code>
    \\  </p>
    \\  <!-- Demo note -->
    \\  <div class="card" style="margin-top:24px;text-align:center">
    \\    <div class="card-label" style="justify-content:center"><span class="dot dot-red"></span> How this works</div>
    \\    <p style="font-size:14px;color:var(--muted);max-width:520px;margin:0 auto;line-height:1.7">
    \\      This entire page is <strong style="color:var(--text)">one Zig file</strong> &mdash;
    \\      <code style="font-family:'SF Mono',monospace;font-size:12px;background:var(--bg3);padding:1px 5px;border-radius:3px">pages/weather.zig</code>.
    \\      Drop it in, run <code style="font-family:'SF Mono',monospace;font-size:12px;background:var(--bg3);padding:1px 5px;border-radius:3px">zig build codegen</code>,
    \\      and the route is live. The charts fetch from Open-Meteo client-side &mdash; zero backend proxy needed.
    \\    </p>
    \\  </div>
    \\
    \\<script>
    \\const WMO = {0:'Clear',1:'Mostly Clear',2:'Partly Cloudy',3:'Overcast',
    \\  45:'Foggy',48:'Fog',51:'Light Drizzle',53:'Drizzle',55:'Heavy Drizzle',
    \\  61:'Light Rain',63:'Rain',65:'Heavy Rain',71:'Light Snow',73:'Snow',75:'Heavy Snow',
    \\  80:'Light Showers',81:'Showers',82:'Heavy Showers',95:'Thunderstorm',96:'Hail Storm',99:'Heavy Hail'};
    \\const WMO_ICON = {0:'☀️',1:'🌤️',2:'⛅',3:'☁️',45:'🌫️',48:'🌫️',
    \\  51:'🌦️',53:'🌧️',55:'🌧️',61:'🌦️',63:'🌧️',65:'🌧️',
    \\  71:'🌨️',73:'❄️',75:'❄️',80:'🌦️',81:'🌧️',82:'⛈️',
    \\  95:'⛈️',96:'🌧️',99:'🌧️'};
    \\
    \\const chartFont = {family:"'DM Sans',system-ui,sans-serif"};
    \\const gridColor = 'rgba(0,0,0,0.06)';
    \\const chartOpts = (unit) => ({
    \\  responsive:true, maintainAspectRatio:false,
    \\  plugins:{legend:{display:false}},
    \\  scales:{
    \\    x:{ticks:{font:chartFont,color:'#8a7f78',maxTicksLimit:12},grid:{display:false}},
    \\    y:{ticks:{font:chartFont,color:'#8a7f78',callback:v=>v+unit},grid:{color:gridColor}}
    \\  },
    \\  elements:{point:{radius:0},line:{tension:0.35,borderWidth:2}},
    \\  interaction:{intersect:false,mode:'index'}
    \\});
    \\
    \\let tempChart, precipChart, windChart;
    \\
    \\function initCharts(){
    \\  const tCtx = document.getElementById('tempChart').getContext('2d');
    \\  tempChart = new Chart(tCtx,{type:'line',data:{labels:[],datasets:[
    \\    {label:'Temp',data:[],borderColor:'#e8251f',backgroundColor:'rgba(232,37,31,0.08)',fill:true},
    \\    {label:'Feels Like',data:[],borderColor:'#8a7f78',borderDash:[4,4],fill:false}
    \\  ]},options:chartOpts('\u00B0C')});
    \\
    \\  const pCtx = document.getElementById('precipChart').getContext('2d');
    \\  precipChart = new Chart(pCtx,{type:'bar',data:{labels:[],datasets:[
    \\    {label:'Precip %',data:[],backgroundColor:'rgba(59,130,246,0.5)',borderRadius:4}
    \\  ]},options:{...chartOpts('%'),plugins:{legend:{display:false}}}});
    \\
    \\  const wCtx = document.getElementById('windChart').getContext('2d');
    \\  windChart = new Chart(wCtx,{type:'line',data:{labels:[],datasets:[
    \\    {label:'Wind',data:[],borderColor:'#22c55e',backgroundColor:'rgba(34,197,94,0.08)',fill:true}
    \\  ]},options:chartOpts(' km/h')});
    \\}
    \\
    \\async function fetchWeather(lat,lon){
    \\  const base = 'https://api.open-meteo.com/v1/forecast';
    \\  const params = `latitude=${lat}&longitude=${lon}`
    \\    + '&current=temperature_2m,relative_humidity_2m,apparent_temperature,weather_code,cloud_cover,surface_pressure,wind_speed_10m,is_day'
    \\    + '&hourly=temperature_2m,apparent_temperature,precipitation_probability,wind_speed_10m'
    \\    + '&daily=temperature_2m_max,temperature_2m_min,weather_code,precipitation_sum,wind_speed_10m_max'
    \\    + '&timezone=auto&forecast_days=7';
    \\  const res = await fetch(`${base}?${params}`);
    \\  return res.json();
    \\}
    \\
    \\function updateCurrent(c){
    \\  document.getElementById('current-loading').style.display='none';
    \\  document.getElementById('current-data').style.display='block';
    \\  document.getElementById('cur-temp').textContent = Math.round(c.temperature_2m)+'\u00B0C';
    \\  document.getElementById('cur-feels').textContent = Math.round(c.apparent_temperature)+'\u00B0';
    \\  document.getElementById('cur-wind').innerHTML = Math.round(c.wind_speed_10m)+'<span class="stat-unit">km/h</span>';
    \\  document.getElementById('cur-humidity').textContent = c.relative_humidity_2m+'%';
    \\  document.getElementById('cur-pressure').innerHTML = Math.round(c.surface_pressure)+'<span class="stat-unit">hPa</span>';
    \\  document.getElementById('cur-cloud').textContent = c.cloud_cover+'%';
    \\  const code = c.weather_code;
    \\  document.getElementById('cur-condition').textContent = WMO[code]||'Unknown';
    \\  document.getElementById('weather-icon').textContent = (c.is_day ? WMO_ICON[code] : '🌙') || '☀️';
    \\}
    \\
    \\function updateCharts(h){
    \\  const hours = h.time.slice(0,24).map(t => t.split('T')[1].slice(0,5));
    \\  tempChart.data.labels = hours;
    \\  tempChart.data.datasets[0].data = h.temperature_2m.slice(0,24);
    \\  tempChart.data.datasets[1].data = h.apparent_temperature.slice(0,24);
    \\  tempChart.update();
    \\
    \\  precipChart.data.labels = hours;
    \\  precipChart.data.datasets[0].data = h.precipitation_probability.slice(0,24);
    \\  precipChart.update();
    \\
    \\  windChart.data.labels = hours;
    \\  windChart.data.datasets[0].data = h.wind_speed_10m.slice(0,24);
    \\  windChart.update();
    \\}
    \\
    \\function updateForecast(d){
    \\  const days = ['Sun','Mon','Tue','Wed','Thu','Fri','Sat'];
    \\  let html = '<div style="display:flex;flex-wrap:wrap;justify-content:center;gap:10px;text-align:center">';
    \\  for(let i=0;i<7;i++){
    \\    const dt = new Date(d.time[i]);
    \\    const day = i===0?'Today':days[dt.getDay()];
    \\    const icon = WMO_ICON[d.weather_code[i]]||'\u2600\uFE0F';
    \\    const hi = Math.round(d.temperature_2m_max[i]);
    \\    const lo = Math.round(d.temperature_2m_min[i]);
    \\    html += '<div class="stat" style="padding:14px 12px;min-width:90px;flex:1;max-width:120px">'
    \\      + '<div class="stat-label">'+day+'</div>'
    \\      + '<div style="font-size:28px;margin:8px 0">'+icon+'</div>'
    \\      + '<div class="stat-value" style="font-size:13px"><span style="color:var(--red)">'+hi+'\u00B0</span> / '+lo+'\u00B0</div>'
    \\      + '<div class="stat-label" style="margin-top:4px;margin-bottom:0">'
    \\      + Math.round(d.precipitation_sum[i])+'mm \u00B7 '+Math.round(d.wind_speed_10m_max[i])+'km/h</div>'
    \\      + '</div>';
    \\  }
    \\  html += '</div>';
    \\  document.getElementById('forecast-grid').innerHTML = html;
    \\}
    \\
    \\async function loadCity(lat,lon){
    \\  const data = await fetchWeather(lat,lon);
    \\  updateCurrent(data.current);
    \\  updateCharts(data.hourly);
    \\  updateForecast(data.daily);
    \\}
    \\
    \\document.getElementById('locations').addEventListener('click', e => {
    \\  const btn = e.target.closest('.loc-btn');
    \\  if(!btn) return;
    \\  document.querySelectorAll('.loc-btn').forEach(b => b.classList.remove('active'));
    \\  btn.classList.add('active');
    \\  loadCity(btn.dataset.lat, btn.dataset.lon);
    \\});
    \\
    \\initCharts();
    \\loadCity(1.29, 103.85);
    \\</script>
;

const page_css =
    \\h1 { font-family:'DM Serif Display',Georgia,serif; font-size:32px; letter-spacing:-0.02em; margin-bottom:8px; }
    \\.subtitle { font-size:14px; color:var(--muted); margin-bottom:32px; }
    \\.card { background:var(--bg2); border:1px solid var(--border); border-radius:12px; padding:24px; margin-bottom:16px; }
    \\.card-label { display:flex; align-items:center; gap:8px; font-size:11px; color:var(--muted); text-transform:uppercase; letter-spacing:0.08em; margin-bottom:20px; }
    \\.dot { width:7px; height:7px; border-radius:50%; flex-shrink:0; }
    \\.dot-red { background:var(--red); }
    \\.dot-pulse { background:var(--red); animation:pulse 2s infinite; }
    \\.dot-blue { background:#3b82f6; }
    \\.dot-green { background:#22c55e; }
    \\@keyframes pulse { 0%,100%{opacity:1} 50%{opacity:0.4} }
    \\.grid2 { display:grid; grid-template-columns:1fr 1fr; gap:12px; }
    \\.grid3 { display:grid; grid-template-columns:1fr 1fr 1fr; gap:12px; }
    \\.grid4 { display:grid; grid-template-columns:1fr 1fr 1fr 1fr; gap:12px; }
    \\.stat { background:var(--bg3); border-radius:8px; padding:16px; }
    \\.stat-label { font-size:11px; color:var(--muted); margin-bottom:6px; }
    \\.stat-value { font-family:'SF Mono','Fira Code',monospace; font-size:15px; color:var(--text); }
    \\.stat-value.red { color:var(--red); }
    \\.stat-value.big { font-size:28px; }
    \\.stat-value.huge { font-size:40px; letter-spacing:-0.03em; }
    \\.stat-unit { font-size:11px; color:var(--muted); margin-left:2px; }
    \\.chart-wrap { position:relative; height:220px; margin-top:12px; }
    \\.chart-wrap canvas { width:100%!important; height:100%!important; }
    \\.location-bar { display:flex; gap:8px; margin-bottom:24px; flex-wrap:wrap; }
    \\.loc-btn { background:var(--bg3); border:1px solid var(--border); border-radius:8px; padding:8px 16px; font-size:13px; font-family:'DM Sans',sans-serif; color:var(--text); cursor:pointer; transition:all 0.15s; }
    \\.loc-btn:hover { background:var(--border); }
    \\.loc-btn.active { background:var(--text); color:var(--bg); border-color:var(--text); }
    \\.weather-icon { font-size:48px; line-height:1; }
    \\.loading { text-align:center; padding:40px; color:var(--muted); font-size:14px; }
    \\.footer-note { font-size:12px; color:var(--muted); text-align:center; margin-top:24px; }
    \\.footer-note a { text-decoration:underline; text-underline-offset:2px; }
    \\.footer-note code { font-family:'SF Mono',monospace; font-size:11px; background:var(--bg3); padding:1px 5px; border-radius:3px; }
    \\@media(max-width:640px) { .grid3,.grid4 { grid-template-columns:1fr 1fr; } }
;
