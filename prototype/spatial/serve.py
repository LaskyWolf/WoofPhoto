# Static server that sends the two headers browsers require before WASM may use several threads.
# usage: python3 serve.py [port]
import os, sys
from functools import partial
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer


class Handler(SimpleHTTPRequestHandler):
    def end_headers(self):
        self.send_header('Cross-Origin-Opener-Policy', 'same-origin')
        self.send_header('Cross-Origin-Embedder-Policy', 'require-corp')
        super().end_headers()


port = int(sys.argv[1]) if len(sys.argv) > 1 else 8765
print(f'Serving on http://localhost:{port}')
ThreadingHTTPServer(('', port), partial(Handler, directory=os.path.dirname(os.path.abspath(__file__)))).serve_forever()
