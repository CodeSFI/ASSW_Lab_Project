# Rol `app_node`

Despliega el **mock HTTP de la API de e-commerce** en los nodos de aplicación
(`srv-ecommerce-app01/02`, capa App) ejecutándolo en un **contenedor Podman
rootless**, escuchando en el puerto `8080` y exponiendo `/health` para que el
balanceador compruebe disponibilidad. Los datos de `/products` se leen **de
PostgreSQL** (data-net), no de un catálogo estático.

Este rol lo consume `ansible/site.yml` dentro del grupo `[app]`.

---

## Estructura de subcarpetas

| Directorio | Rol | Contenido |
|---|---|---|
| `tasks/` | **Lógica del rol** | `main.yml`: instalación de Podman rootless, build de la imagen, despliegue de la unidad systemd (ver fichero resumen abajo). |
| `handlers/` | **Acciones bajo demanda** | `main.yml`: `restart mock-app` — recrea el contenedor cuando cambia el código, la configuración o la unidad. |
| `defaults/` | **Variables por defecto** | `main.yml`: puerto, usuario/directorio, nombres de imagen/contenedor, rango subuid, conexión a la BD. |
| `templates/` | **Ficheros J2 plantillados** | Unidad systemd del contenedor y fichero de entorno de la app (ver tabla de plantillas abajo). |
| `files/` | **Ficheros estáticos** | `mock_api.py`, `Containerfile` y `containers-network.conf` (netavark con `firewall_driver = "none"`). |

---

## `tasks/main.yml` (resumen de pasos)

1. **Instalar Podman rootless**: `podman`, `uidmap`, `slirp4netns`,
   `fuse-overlayfs` y `curl`.
2. **Configurar netavark sin firewalld** (`containers-network.conf` →
   `/etc/containers/containers.conf.d/20-mockapp-firewall-none.conf`): estos
   nodos tienen firewalld instalado pero **inactivo**, y netavark se queda
   colgado en su helper `firewalld-reload`; como el filtrado lo hacen los
   Security Groups de OpenStack, se usa `firewall_driver = "none"`.
3. **Crear usuario de sistema** `mockapp` (sin login). Registrar su rango
   **subuid/subgid** en `/etc/subuid` y `/etc/subgid` (mapeo rootless) y
   **habilitar linger** (`loginctl enable-linger`): el build rootless necesita la
   sesión de usuario de systemd (`user@<uid>.service`); sin ella, crun falla al
   crear el contenedor con `sd-bus ... Access denied ... interactive authentication`.
4. **Limpiar procesos podman de ejecuciones cortadas** (build/run anteriores que
   retienen el storage lock) y, si `app_node_reset_podman_storage: true`, borrar
   el storage rootless para re-construir desde cero.
5. **Preparar directorios**: `mock_home`, contexto de build y runtime
   (`/run/mockapp`).
6. **Desplegar el código** (`mock_api.py` + `Containerfile`) en el contexto de
   build y el **fichero de entorno** `mock-app.env` (modo `0600`, con los
   secretos de la BD).
7. **Construir la imagen** `localhost/mock-ecommerce` con `podman build`
   (idempotente: solo se reconstruye si cambia el hash del código fuente).
8. **Desplegar la unidad systemd** y habilitar/arrancar el contenedor.

> **Rootless, de verdad:** `podman run` se ejecuta bajo el usuario `mockapp`
> sin privilegios. El contenedor usa el espacio de usuarios mapeado vía
> `newuidmap`/`newgidmap`. La orquestación se hace desde una unidad **system**
> (`User=`/`RuntimeDirectory=`), lo que conserva el nombre `mock-app.service`
> que usan los tests de failover. El **build** de imágenes sí necesita la
> sesión de usuario de systemd, por eso el rol habilita *linger* para
> `mockapp`; el contenedor en runtime (con `--cgroups=disabled`) no depende
> de esa sesión.

---

## Plantillas `templates/` `.j2`

| Fichero `.j2` | Destino en el nodo | Qué hace |
|---|---|---|
| `mock-app.service.j2` | `/etc/systemd/system/mock-app.service` | Unidad system que ejecuta `podman run --rm -p 8080:8080` como usuario `mockapp`, con `Restart=on-failure`, `--cgroups=disabled` y `XDG_RUNTIME_DIR=/run/mockapp`. |
| `mock-app.env.j2` | `/opt/mock-ecommerce/mock-app.env` | Variables de entorno del contenedor: puerto HTTP, host y datos de conexión a PostgreSQL (modo `0600`). |

---

## `files/Containerfile`

Imagen `python:3.11-slim` con `psycopg2-binary`, copia de `mock_api.py`, y
arranque como usuario sin privilegios (`nobody`). Se construye en el propio
nodo; el contexto de build (`{{ mock_home }}/build`) está **aislado** para que
`mock-app.env` (con secretos) no entre en el contexto ni en la imagen.

---

## `files/mock_api.py`

Servidor HTTP en Python (stdlib + `psycopg2`) que **lee los productos de
PostgreSQL**:

- `GET /health` → `{"status": "ok", ..., "host": <nodo>, "db": "up"|"down"}`.
- `GET /dbcheck` → `200` si la BD responde, `503` si no (registro en el log).
- `GET /products` → listado de productos desde la tabla `products`.
- `GET /products/<id>` → un producto, o `404`.
- Resto de rutas → `404` en JSON.

Al arrancar, el propio mock **crea la tabla `products` y la siembra** con el
catálogo original si está vacía (idempotente, sin tocar el rol `database`). Si
la BD no está disponible el proceso arranca igualmente: `/health` sigue
respondiendo y los endpoints de negocio devuelven `503` (el balanceador no
retira el nodo).

La conexión usa las variables `MOCK_DB_HOST/PORT/NAME/USER/PASSWORD` que
inyecta `mock-app.env`.

---

## Variables utilizadas

Definidas en `defaults/main.yml` (los valores `ecommerce_db_*` y
`postgresql_port` provienen de `group_vars/all.yml`):

| Variable | Uso |
|---|---|
| `app_http_port` | Puerto donde escucha el mock dentro del contenedor y que se publica en el host (`8080`); el LB balancea a este puerto en app-net. |
| `mock_user` | Usuario de sistema ejecutor del contenedor rootless (`mockapp`). |
| `mock_home` | Directorio del mock (`/opt/mock-ecommerce`). |
| `mock_image_name/tag` | Imagen local `localhost/mock-ecommerce:latest` (nunca se baja de un registro). |
| `mock_container_name` | Nombre del contenedor (`mock-app`). |
| `mock_build_dir` | Contexto de build (`{{ mock_home }}/build`). |
| `mock_runtime_dir_name` | Directorio runtime creado por systemd en `/run` (`mockapp`). |
| `mock_subuid_start/range` | Rango subuid/subgid para el mapeo rootless (`200000:65536`). |
| `app_node_reset_podman_storage` | Reset opt-in del storage rootless (`false` por defecto): borra la imagen/capas para recuperar un storage "cuña" (build colgado). |
| `mock_db_host/port/name/user/password` | Conexión a PostgreSQL por data-net (`10.10.30.50:5432`). |

---

## Verificación

```bash
# 1) Servicio activo y habilitado en ambos app-nodes
ansible app -m shell -a "systemctl is-active mock-app.service && systemctl is-enabled mock-app.service"

# 2) El contenedor corre rootless (sin root) y escucha en 8080
ansible app -m shell -a "podman ps --format '{{.Names}} (user {{.User}})' ; ss -ltn | grep 8080"

# 3) /health identifica el nodo y dice si la BD responde
ansible app -m shell -a "curl -s http://127.0.0.1:8080/health"

# 4) /products lee de PostgreSQL (productos desde la tabla `products`)
ansible app -m shell -a "curl -s http://127.0.0.1:8080/products"

# 5) Logs del contenedor vía systemd
ansible app -m shell -a "journalctl -u mock-app.service -n 20 --no-pager"
```

---

## Notas y dependencias

- **Podman real en los nodos:** los app-nodes traen **podman 5.7.0**
  (resuelto por `apt`, no 3.4.4 como se asumía) con backend de red **netavark**.
  El rol es compatible, pero netavark requiere la nota de firewalld de arriba.
- **Storage "cuña" (build colgado en `jbd2_log_wait_commit`):** la unidad
  OpenStack `vda1` (ext4) se **bloquea por tramos** (kernel: `task ... blocked
  for more than 120 seconds` en `jbd2_log_wait_commit`). Si un build se
  interrumpe durante uno de esos bloqueos, el storage rootless puede quedar en
  un estado que cuelga a podman aunque el disco esté sano. Recuperación:
  `app_node_reset_podman_storage: true` (borra el storage y fuerza
  re-descarga/re-build) o `rm -rf {{ mock_home }}/.local/share/containers/storage`
  como `{{ mock_user }}`. Detalle en `docs/soluciones-ansible-errores.md` §5.
- **SG `db_from_app` (resuelto en el repo):** `terraform/security_groups.tf` ahora
  permite el 5432 entrante a la BD **solo desde data-net** (`10.10.30.0/24`), la ruta
  real Apps→DB, alineado con el `pg_hba.conf` del rol `database`. **Pendiente de
  aplicar**: ejecutar `terraform apply` al gestionar la infra (o corregirlo a mano en
  Horizon). Sin ese apply, `/products` devolverá `503` (`db_unavailable`).
- **Red del contenedor:** el contenedor rootless sale por el host (slirp4netns);
  la conexión a `10.10.30.50:5432` sale por la interfaz data-net del app-node, de
  modo que PostgreSQL ve la IP esperada (`10.10.30.11`/`.12`).
- **Build:** la primera ejecución descarga `python:3.11-slim` y
  `psycopg2-binary` (los app-nodes salen a Internet por SNAT). Si el registro
  no es accesible, el playbook falla en la tarea de build con un error claro.
- **Imagen desactualizada:** se reconstruye automáticamente cuando cambia el
  hash de `mock_api.py` o `Containerfile` (etiqueta `src_hash` en la imagen).
- **Cgroups:** en runtime, `--cgroups=disabled` hace que el contenedor no exija
  gestión propia de cgroups; el *build*, en cambio, sí la necesita, y con
  *linger* + `XDG_RUNTIME_DIR=/run/user/<uid>` construye sin errores de
  `sd-bus`. Suficiente para un único contenedor.
- **Linger (build rootless):** el rol activa `loginctl enable-linger mockapp`.
  Es la vía estándar para que Podman rootless cree contenedores sin una sesión
  interactiva (crun usa el bus del usuario para gestionar los cgroups). No afecta
  al nombre de la unidad (`mock-app.service`), que sigue siendo una unidad **system**.
- **Troubleshooting:** si el contenedor no arranca, revisar
  `journalctl -u mock-app.service -n 50` y `podman logs --latest` como
  `{{ mock_user }}`.