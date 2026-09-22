#!/usr/bin/env python3
"""Mock API de la tienda e-commerce. Solo stdlib, sin dependencias externas.

Serves minimal JSON endpoints and a /health probe for the load balancer.
Intended to run under systemd as an unprivileged user.
"""
import json
import sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

PRODUCTS = [
    {"id": 1, "name": "Camiseta basica", "price": 12.99},
    {"id": 2, "name": "Sudadera hoodie", "price": 29.5},
    {"id": 3, "name": "Gorra snapback", "price": 15.0},
    {"id": 4, "name": "Calcetines 3 pack", "price": 8.4},
]


def send_json(handler, payload, status=200):
    body = json.dumps(payload).encode("utf-8")
    handler.send_response(status)
    handler.send_header("Content-Type", "application/json")
    handler.send_header("Content-Length", str(len(body)))
    handler.end_headers()
    handler.wfile.write(body)


class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        path = self.path.split("?", 1)[0]
        if path == "/health":
            send_json(self, {"status": "ok", "service": "mock-ecommerce"})
        elif path == "/products":
            send_json(self, {"products": PRODUCTS})
        elif path.startswith("/products/"):
            product_id = path.rsplit("/", 1)[-1]
            try:
                product_id = int(product_id)
            except ValueError:
                product_id = None
            found = next((p for p in PRODUCTS if p["id"] == product_id), None)
            if found is None:
                send_json(self, {"error": "not_found"}, status=404)
            else:
                send_json(self, found)
        else:
            send_json(self, {"error": "not_found"}, status=404)

    def log_message(self, fmt, *args):
        sys.stderr.write("%s - %s\n" % (self.address_string(), fmt % args))


if __name__ == "__main__":
    port = int(sys.argv[1]) if len(sys.argv) > 1 else 8080
    ThreadingHTTPServer(("0.0.0.0", port), Handler).serve_forever()