// Minimal static server for tailnet HTTP pull (node, no deps).
const http = require('http');
const fs = require('fs');
const path = require('path');
const ROOT = 'E:/MyLLM_exp/r2ctx';
const PORT = 8123;
http.createServer((req, res) => {
  const f = path.join(ROOT, path.basename(req.url.split('?')[0]));
  fs.stat(f, (e, st) => {
    if (e) { res.writeHead(404); res.end('nf'); return; }
    let start = 0;
    const rng = req.headers.range;
    if (rng) { const m = /bytes=(\d*)-(\d*)/.exec(rng); if (m) { start = parseInt(m[1]||'0',10); } }
    const end = st.size - 1;
    const headers = { 'Content-Type': 'application/octet-stream',
      'Accept-Ranges': 'bytes', 'Content-Length': end - start + 1 };
    if (rng) headers['Content-Range'] = `bytes ${start}-${end}/${st.size}`;
    res.writeHead(rng ? 206 : 200, headers);
    fs.createReadStream(f, { start, end }).pipe(res);
  });
}).listen(PORT, '0.0.0.0', () => console.log('SERVING', ROOT, 'on', PORT));
