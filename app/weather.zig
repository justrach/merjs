const mer = @import("mer");
const h = mer.h;

pub const meta: mer.Meta = .{
    .title = "Weather",
    .description = "Live weather dashboard powered by Open-Meteo. Temperature, precipitation, wind, and 7-day forecast.",
    .og_title = "merjs Weather \u{2014} Live Global Forecasts",
    .og_description = "Real-time weather data rendered by a Zig web framework with zero Node.js.",
    .og_type = "website",
    .twitter_card = "summary_large_image",
};

const page_node = page();

pub fn render(req: mer.Request) mer.Response {
    return mer.render(req.allocator, page_node);
}

fn locBtn(label: []const u8, lat: []const u8, lon: []const u8, active: bool) h.Node {
    return h.button(if (active) .{
        .class = "loc-btn active",
        .extra = &.{
            .{ .name = "data-lat", .value = lat },
            .{ .name = "data-lon", .value = lon },
        },
    } else .{
        .class = "loc-btn",
        .extra = &.{
            .{ .name = "data-lat", .value = lat },
            .{ .name = "data-lon", .value = lon },
        },
    }, label);
}

fn statEl(lbl: []const u8, id: []const u8) h.Node {
    return h.div(.{ .class = "stat" }, .{
        h.div(.{ .class = "stat-label" }, lbl),
        h.div(.{ .class = "stat-value", .id = id }, .{h.raw("&mdash;")}),
    });
}

fn page() h.Node {
    return h.documentLang("en", .{
        // Head
        h.charset("UTF-8"),
        h.viewport("width=device-width, initial-scale=1.0"),
        h.title("Weather \u{2014} merjs"),
        h.description("Live weather dashboard powered by Open-Meteo. Temperature, precipitation, wind, and 7-day forecast."),
        h.og("og:type", "website"),
        h.og("og:site_name", "merjs"),
        h.og("og:title", "merjs Weather \u{2014} Live Global Forecasts"),
        h.og("og:description", "Real-time weather data rendered by a Zig web framework with zero Node.js."),
        h.meta(.{ .name = "twitter:card", .content = "summary_large_image" }),
        h.meta(.{ .name = "twitter:title", .content = "merjs Weather \u{2014} Live Global Forecasts" }),
        h.meta(.{ .name = "twitter:description", .content = "Live weather dashboard powered by Open-Meteo, served by Zig." }),
        h.link(.{ .rel = "preconnect", .href = "https://fonts.googleapis.com" }),
        h.link(.{ .href = "https://fonts.googleapis.com/css2?family=DM+Serif+Display:ital@0;1&family=DM+Sans:wght@400;500;600&display=swap", .rel = "stylesheet" }),
        h.scriptSrc(.{ .src = "https://cdn.jsdelivr.net/npm/chart.js@4/dist/chart.umd.min.js" }),
        h.style(css),
    }, .{
        // Body
        h.div(.{ .class = "page" }, .{
            // Header
            h.header(.{ .class = "header" }, .{
                h.a(.{ .href = "/", .class = "wordmark" }, .{ h.text("mer"), h.span(.{}, .{h.raw("js")}) }),
                h.a(.{ .href = "/", .class = "back" }, .{h.raw("&larr; home")}),
            }),
            h.h1(.{}, "Weather"),
            h.p(.{ .class = "subtitle" }, .{h.raw("Live data from Open-Meteo &mdash; rendered client-side, fetched from a free API, charted with Chart.js")}),

            // Location bar
            h.div(.{ .class = "location-bar", .id = "locations" }, .{
                locBtn("Singapore", "1.29", "103.85", true),
                locBtn("Tokyo", "35.68", "139.69", false),
                locBtn("New York", "40.71", "-74.01", false),
                locBtn("London", "51.51", "-0.13", false),
                locBtn("Sydney", "-33.87", "151.21", false),
            }),

            // Current conditions card
            h.div(.{ .class = "card", .id = "current-card" }, .{
                h.div(.{ .class = "card-label" }, .{ h.span(.{ .class = "dot dot-pulse" }, ""), h.raw(" Current conditions") }),
                h.div(.{ .class = "loading", .id = "current-loading" }, .{h.raw("Fetching weather data&hellip;")}),
                h.div(.{ .id = "current-data", .style = "display:none" }, .{
                    h.div(.{ .class = "grid4" }, .{
                        h.div(.{ .class = "stat", .style = "grid-column:1/3" }, .{
                            h.div(.{ .class = "stat-label" }, "temperature"),
                            h.div(.{ .style = "display:flex;align-items:center;gap:16px" }, .{
                                h.div(.{ .class = "weather-icon", .id = "weather-icon" }, ""),
                                h.div(.{ .class = "stat-value huge red", .id = "cur-temp" }, .{h.raw("&mdash;")}),
                            }),
                        }),
                        statEl("feels like", "cur-feels"),
                        statEl("wind", "cur-wind"),
                    }),
                    h.div(.{ .class = "grid4", .style = "margin-top:12px" }, .{
                        statEl("humidity", "cur-humidity"),
                        statEl("pressure", "cur-pressure"),
                        statEl("cloud cover", "cur-cloud"),
                        statEl("condition", "cur-condition"),
                    }),
                }),
            }),

            // Temperature chart
            h.div(.{ .class = "card" }, .{
                h.div(.{ .class = "card-label" }, .{ h.span(.{ .class = "dot dot-red" }, ""), h.raw(" 24-hour temperature") }),
                h.div(.{ .class = "chart-wrap" }, .{h.el("canvas", .{ .id = "tempChart" }, "")}),
            }),

            // Precipitation chart
            h.div(.{ .class = "card" }, .{
                h.div(.{ .class = "card-label" }, .{ h.span(.{ .class = "dot dot-blue" }, ""), h.raw(" Precipitation probability") }),
                h.div(.{ .class = "chart-wrap" }, .{h.el("canvas", .{ .id = "precipChart" }, "")}),
            }),

            // Wind chart
            h.div(.{ .class = "card" }, .{
                h.div(.{ .class = "card-label" }, .{ h.span(.{ .class = "dot dot-green" }, ""), h.raw(" Wind speed") }),
                h.div(.{ .class = "chart-wrap" }, .{h.el("canvas", .{ .id = "windChart" }, "")}),
            }),

            // 7-day forecast
            h.div(.{ .class = "card" }, .{
                h.div(.{ .class = "card-label" }, .{ h.span(.{ .class = "dot dot-red" }, ""), h.raw(" 7-day forecast") }),
                h.div(.{ .class = "loading", .id = "forecast-grid" }, .{h.raw("Loading&hellip;")}),
            }),

            // Footer note
            h.p(.{ .class = "footer-note" }, .{
                h.raw("Powered by "),
                h.a(.{ .href = "https://open-meteo.com/" }, "Open-Meteo"),
                h.raw(" &middot; charts via "),
                h.a(.{ .href = "https://www.chartjs.org/" }, "Chart.js"),
                h.raw(" &middot; served by "),
                h.code(.{}, "merjs"),
            }),

            // Demo note card
            h.div(.{ .class = "card", .style = "margin-top:24px;text-align:center" }, .{
                h.div(.{ .class = "card-label", .style = "justify-content:center" }, .{
                    h.span(.{ .class = "dot dot-red" }, ""),
                    h.raw(" How this works"),
                }),
                h.p(.{ .style = "font-size:14px;color:var(--muted);max-width:520px;margin:0 auto;line-height:1.7" }, .{
                    h.raw("This entire page is "),
                    h.strong(.{ .style = "color:var(--text)" }, "one Zig file"),
                    h.raw(" &mdash; "),
                    h.code(.{ .style = "font-family:'SF Mono',monospace;font-size:12px;background:var(--bg3);padding:1px 5px;border-radius:3px" }, "pages/weather.zig"),
                    h.raw(". Drop it in, run "),
                    h.code(.{ .style = "font-family:'SF Mono',monospace;font-size:12px;background:var(--bg3);padding:1px 5px;border-radius:3px" }, "zig build codegen"),
                    h.raw(", and the route is live. The charts fetch from Open-Meteo client-side &mdash; zero backend proxy needed."),
                }),
            }),
        }),

        // Script
        h.script(.{}, js),
    });
}

const css =
    \\*, *::before, *::after { box-sizing: border-box; margin: 0; padding: 0; }
    \\:root { --bg:#f0ebe3; --bg2:#e8e2d9; --bg3:#ddd5cc; --text:#252530; --muted:#8a7f78; --border:#d5cdc4; --red:#e8251f; }
    \\body { background:var(--bg); color:var(--text); font-family:'DM Sans',system-ui,sans-serif; min-height:100vh; }
    \\a { color:inherit; text-decoration:none; }
    \\.page { max-width:780px; margin:0 auto; padding:48px 32px 96px; }
    \\.header { display:flex; align-items:center; justify-content:space-between; margin-bottom:48px; }
    \\.wordmark { font-family:'DM Serif Display',Georgia,serif; font-size:18px; letter-spacing:-0.02em; }
    \\.wordmark span { color:var(--red); }
    \\.back { font-size:13px; color:var(--muted); transition:color 0.15s; }
    \\.back:hover { color:var(--text); }
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

const js =
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
;
