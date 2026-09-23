# Rol `app_node`

Despliega el **mock HTTP de la API de e-commerce** en los nodos de
aplicación (`srv-ecommerce-app01/02`, capa App, red de aplicación
`10.10.20.0/24`), escuchando en el puerto `8080` y exponiendo el endpoint
`/health` para que el balanceador compruebe disponibilidad.

Este rol lo consume `ansible/site.yml` dentro del grupo `[app]`.

---

## Estructura de subcarpetas

| Directorio | Rol | Contenido |
|---|---|---|
| `tasks/` | **Lógica del rol** | `main.yml` con los pasos de instalación y arranque del mock (ver fichero resumen abajo). |
| `handlers/` | **Acciones bajo demanda** | `main.yml`: `restart mock-app` — reinicia el servicio cuando cambia el código o la unidad systemd. |
| `defaults/` | **Variables por defecto** | `main.yml`: puerto de escucha, usuario y directorio del mock. |
| `templates/` | **Ficheros J2 plantillados** | Unidad systemd del servicio (ver tabla de plantillas abajo). |
| `files/` | **Ficheros estáticos** | `mock_api.py`: el servidor HTTP del mock, copiado en la VM sin cambios. |

---

## `tasks/main.yml` (resumen de pasos)

1. **Instalar dependencias**: `python3` y `curl`.
2. **Crear usuario de sistema** `mockapp` (sin login, mínimos privilegios).
3. **Copiar el mock**: `files/mock_api.py` → `/opt/mock-ecommerce/`.
4. **Desplegar unidad systemd** + habilitar y arrancar el servicio.

> Evolución futura (Plan de Fran): empaquetar el mock en un contenedor Podman
> rootless. Hoy se ejecuta como proceso systemd con `NoNewPrivileges=true`.

---

## Plantillas `templates/` `.j2`

| Fichero `.j2` | Destino en el nodo | Qué hace |
|---|---|---|
| `mock-app.service.j2` | `/etc/systemd/system/mock-app.service` | Unidad systemd `simple` que ejecuta el mock como usuario `mockapp`, con `Restart=on-failure` (arranque automático ante caídas) y `NoNewPrivileges=true`. |

---

## `files/mock_api.py`

Servidor HTTP en **Python estándar** (sin dependencias externas, solo stdlib):

- `GET /health` → `{"status": "ok"}` — sonda para el balanceador.
- `GET /products` → listado de productos.
- `GET /products/<id>` → un producto o `404`.
- Resto de rutas → `404` en JSON.

Se copia tal cual con `ansible.builtin.copy`; cualquier cambio en el fichero
dispara el handler `restart mock-app`.

---

## Variables utilizadas

Definidas en `defaults/main.yml`:

| Variable | Uso |
|---|---|
| `app_http_port` | Puerto donde escucha el mock (`8080`); el LB balancea a este puerto en app-net. |
| `mock_user` | Usuario de sistema ejecutor del mock (`mockapp`). |
| `mock_home` | Directorio del mock (`/opt/mock-ecommerce`). |