// worker.js — Cloudflare Worker to serve merjs installer
// Add this route to your existing worker

export default {
  async fetch(request, env, ctx) {
    const url = new URL(request.url);
    
    // Serve install.sh
    if (url.pathname === '/install.sh' || url.pathname === '/install') {
      // Fetch from GitHub raw content
      const installScript = await fetch('https://raw.githubusercontent.com/justrach/merjs/main/install.sh', {
        cf: { cacheTtl: 3600 }
      });
      
      return new Response(installScript.body, {
        status: 200,
        headers: {
          'Content-Type': 'text/x-shellscript; charset=utf-8',
          'Cache-Control': 'public, max-age=3600',
        },
      });
    }
    
    // Serve index.html (optional - host your own or redirect to GitHub)
    if (url.pathname === '/' || url.pathname === '/index.html') {
      const html = `<!DOCTYPE html>
<html>
<head><title>merjs — Install</title></head>
<body>
  <h1>🚀 merjs</h1>
  <p>Next.js-style web framework in Zig</p>
  <h2>Quick Install</h2>
  <pre><code>curl -fsSL https://${url.hostname}/install.sh | bash</code></pre>
  <p><a href="https://github.com/justrach/merjs">GitHub</a></p>
</body>
</html>`;
      
      return new Response(html, {
        status: 200,
        headers: { 'Content-Type': 'text/html; charset=utf-8' },
      });
    }
    
    // Pass through to your existing worker logic
    return new Response('Not found', { status: 404 });
  },
};
