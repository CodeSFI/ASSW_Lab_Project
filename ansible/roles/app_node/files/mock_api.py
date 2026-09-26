#!/usr/bin/env python3
"""Mock API de la tienda e-commerce, con datos reales de PostgreSQL.

Sirve endpoints JSON y la sonda /health para el balanceador. Los productos se
leen de la base de datos (variables MOCK_DB_*); si la BD no esta disponible el
proceso arranca igualmente y los endpoints de negocio devuelven 503 (la sonda
/health sigue respondiendo para que el balanceador no retire el nodo).

Se ejecuta dentro de un contenedor Podman rootless (rol app_node). Requiere
psycopg2, que se instala en la imagen durante el build (ver Containerfile).
"""
import json
import os
import socket
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

import psycopg2

HOST = os.environ.get("MOCK_HOST") or socket.gethostname()

DB_CONFIG = {
    "host": os.environ.get("MOCK_DB_HOST") or "127.0.0.1",
    "port": int(os.environ.get("MOCK_DB_PORT") or "5432"),
    "dbname": os.environ.get("MOCK_DB_NAME") or "ecommerce",
    "user": os.environ.get("MOCK_DB_USER") or "",
    "password": os.environ.get("MOCK_DB_PASSWORD") or "",
    "connect_timeout": 3,
}

# Catalogo base con el que se siembra la tabla `products` la primera vez
# (mismo catalogo que la version estatica original del mock).
SEED_PRODUCTS = [
    (1, "Camiseta basica", 12.99),
    (2, "Sudadera hoodie", 29.5),
    (3, "Gorra snapback", 15.0),
    (4, "Calcetines 3 pack", 8.4),
]


def db_connect():
    """Devuelve una conexion a PostgreSQL, o None si falla."""
    try:
        return psycopg2.connect(**DB_CONFIG)
    except psycopg2.Error as exc:
        sys.stderr.write("DB connect error: %s\n" % exc)
        return None


def db_up():
    """Comprueba con un SELECT 1 que la BD responde ahora mismo."""
    conn = db_connect()
    if conn is None:
        return False
    try:
        with conn.cursor() as cur:
            cur.execute("SELECT 1")
            cur.fetchone()
        return True
    except psycopg2.Error:
        return False
    finally:
        conn.close()


def init_db():
    """Crea la tabla `products` si no existe y la siembra si esta vacia.

    Best effort: si la BD no responde al arrancar, el mock continua sirviendo
    /health y devuelve 503 en los endpoints que la consultan.
    """
    conn = db_connect()
    if conn is None:
        return False
    try:
        with conn.cursor() as cur:
            cur.execute(
                """
                CREATE TABLE IF NOT EXISTS products (
                    id    INTEGER PRIMARY KEY,
                    name  TEXT NOT NULL,
                    price NUMERIC(10, 2) NOT NULL
                )
                """
            )
            cur.execute("SELECT COUNT(*) FROM products")
            if cur.fetchone()[0] == 0:
                cur.executemany(
                    "INSERT INTO products (id, name, price) VALUES (%s, %s, %s)",
                    SEED_PRODUCTS,
                )
        conn.commit()
        return True
    except psycopg2.Error as exc:
        conn.rollback()
        sys.stderr.write("DB init error: %s\n" % exc)
        return False
    finally:
        conn.close()


def fetch_products():
    """Devuelve la lista de productos, o None si la BD falla."""
    conn = db_connect()
    if conn is None:
        return None
    try:
        with conn.cursor() as cur:
            cur.execute("SELECT id, name, price FROM products ORDER BY id")
            rows = cur.fetchall()
        return [{"id": r[0], "name": r[1], "price": float(r[2])} for r in rows]
    except psycopg2.Error as exc:
        sys.stderr.write("DB products error: %s\n" % exc)
        return None
    finally:
        conn.close()


def fetch_product(product_id):
    """Devuelve un producto, None si no existe, o "db_error" si la BD falla."""
    conn = db_connect()
    if conn is None:
        return "db_error"
    try:
        with conn.cursor() as cur:
            cur.execute(
                "SELECT id, name, price FROM products WHERE id = %s",
                (product_id,),
            )
            row = cur.fetchone()
        if row is None:
            return None
        return {"id": row[0], "name": row[1], "price": float(row[2])}
    except psycopg2.Error as exc:
        sys.stderr.write("DB product error: %s\n" % exc)
        return "db_error"
    finally:
        conn.close()


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
            send_json(
                self,
                {
                    "status": "ok",
                    "service": "mock-ecommerce",
                    "host": HOST,
                    "db": "up" if db_up() else "down",
                },
            )
        elif path == "/dbcheck":
            up = db_up()
            send_json(
                self,
                {"db": "up" if up else "down", "host": HOST},
                status=200 if up else 503,
            )
        elif path == "/products":
            products = fetch_products()
            if products is None:
                send_json(self, {"error": "db_unavailable", "host": HOST}, status=503)
            else:
                send_json(self, {"host": HOST, "products": products})
        elif path.startswith("/products/"):
            product_id = path.rsplit("/", 1)[-1]
            try:
                product_id = int(product_id)
            except ValueError:
                product_id = None
            if product_id is None:
                send_json(self, {"error": "not_found"}, status=404)
                return
            product = fetch_product(product_id)
            if product == "db_error":
                send_json(self, {"error": "db_unavailable", "host": HOST}, status=503)
            elif product is None:
                send_json(self, {"error": "not_found"}, status=404)
            else:
                send_json(self, product)
        else:
            send_json(self, {"error": "not_found"}, status=404)

    def log_message(self, fmt, *args):
        sys.stderr.write("%s - %s\n" % (self.address_string(), fmt % args))


if __name__ == "__main__":
    port = int(os.environ.get("MOCK_HTTP_PORT") or "8080")
    if len(sys.argv) > 1:
        port = int(sys.argv[1])

    def _init_db_loop():
        """Reintenta init_db() cada 15 s hasta que la BD responde y la tabla
        products esta creada/sembrada.

        Tolerancia al orden de suministro: si este contenedor arranca antes que
        el PostgreSQL (o mientras la BD reinicia), la tabla se crea en cuanto
        la BD esta disponible sin necesidad de reiniciar el contenedor.
        """
        while not init_db():
            time.sleep(15)

    threading.Thread(target=_init_db_loop, name="db-init-retry", daemon=True).start()

    sys.stderr.write(
        "Mock e-commerce listening 0.0.0.0:%d host=%s db=%s:%s/%s\n"
        % (port, HOST, DB_CONFIG["host"], DB_CONFIG["port"], DB_CONFIG["dbname"])
    )
    ThreadingHTTPServer(("0.0.0.0", port), Handler).serve_forever()