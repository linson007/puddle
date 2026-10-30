#!/usr/bin/env python3
"""Disposable loopback-only page for live browser acceptance; no real accounts."""
import json
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlparse, parse_qs

state = {"mode": "normal", "events": []}
page = b'''<!doctype html><meta charset="utf-8"><title>Puddle local browser acceptance</title>
<h1>Puddle local browser acceptance</h1><p>Synthetic data only. Nothing leaves this loopback server.</p>
<label>Test note <input id="note"></label>
<label>Password test field <input type="password" autocomplete="current-password"></label>
<label>Card number test field <input autocomplete="cc-number" inputmode="numeric"></label>
<label>One-time code test field <input autocomplete="one-time-code"></label>
<button id="action">Record local test</button><output id="result">No action recorded</output>
<p><a href="/next">Next local page</a> <a href="/next" target="_blank">Open second local tab</a></p>
<div style="height:1200px">Scroll fixture</div><p>End of local fixture</p>
<script>
const report = value => fetch('/event?value='+encodeURIComponent(value));
document.querySelector('#note').addEventListener('input', e => report('typed:'+e.target.value));
document.querySelector('#action').onclick = e => {report(e.target.textContent);document.querySelector('#result').textContent='Local action recorded';};
let previous='normal';
setInterval(async()=>{const {mode}=await (await fetch('/state')).json();if(mode===previous)return;previous=mode;
if(mode==='navigate')location.href='/next';
if(mode==='relabel')document.querySelector('#action').textContent='Changed local action';
if(mode==='replace'){const old=document.querySelector('#action');const b=old.cloneNode(true);b.textContent='Replacement local action';b.onclick=()=>report('replacement clicked');old.replaceWith(b);}
if(mode==='password')document.querySelector('#note').type='password';
},250);
</script>'''

class Handler(BaseHTTPRequestHandler):
    def log_message(self, *_):
        pass

    def do_GET(self):
        url = urlparse(self.path)
        query = parse_qs(url.query)
        content_type = 'application/json'
        if url.path == '/state':
            body = json.dumps(state).encode()
        elif url.path == '/control':
            state['mode'] = query.get('mode', ['normal'])[0]
            body = b'{}'
        elif url.path == '/event':
            state['events'].append(query.get('value', [''])[0][:4000])
            body = b'{}'
        elif url.path == '/next':
            content_type = 'text/html; charset=utf-8'
            body = b'<title>Puddle second local page</title><h1>Second local page</h1><p>Navigation verified.</p>'
        else:
            content_type = 'text/html; charset=utf-8'
            body = page
        self.send_response(200)
        self.send_header('Content-Type', content_type)
        self.send_header('Cache-Control', 'no-store')
        self.send_header('Content-Length', str(len(body)))
        self.end_headers()
        self.wfile.write(body)

if __name__ == '__main__':
    server = ThreadingHTTPServer(('127.0.0.1', 0), Handler)
    print(f'http://127.0.0.1:{server.server_port}/', flush=True)
    server.serve_forever()
