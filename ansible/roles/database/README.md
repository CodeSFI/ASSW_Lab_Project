# Rol `database`

Despliega **PostgreSQL** en el servidor de datos (`srv-db-core01`, capa Data,
red aislada `10.10.30.0/24`), crea la base y el usuario de la aplicación, y
configura un **backup diario cifrado con GPG**.

Este rol lo consume `ansible/site.yml` dentro del grupo `[db]`.

---

## Estructura de subcarpetas

| Directorio | Rol | Contenido |
|---|---|---|
| `tasks/` | **Lógica del rol** | `main.yml` con los pasos de instalación y configuración (ver fichero resumen abajo). |
| `handlers/` | **Acciones bajo demanda** | `main.yml`: `restart postgresql` — se dispara cuando cambia la configuración de escucha o `pg_hba.conf`. |
| `defaults/` | **Variables por defecto** | `main.yml`: versión de PostgreSQL, IP de escucha en data-net y rango autorizado de la aplicación. |
| `templates/` | **Ficheros J2 plantillados** | Ficheros `.j2` que se rellenan con variables del rol al desplegarse (ver tabla de plantillas abajo). |
| `files/` | **Ficheros estáticos** | Actualmente vacío (solo `.gitkeep`); para futuros scripts/archivos que se copian tal cual. |

---

## `tasks/main.yml` (resumen de pasos)

1. **Instalar dependencias**: `postgresql`, `postgresql-contrib`, `python3-psycopg2` (para los módulos Ansible) y `gpg`.
2. **Configurar escucha** → plantilla `conf.d-supply.conf.j2`: `listen_addresses` solo en la IP de data-net.
3. **Restringir acceso** → plantilla `pg_hba.conf.j2`: permite conexiones únicamente desde la red de datos de la aplicación.
4. **Crear rol y base de datos** de la aplicación con los secretos de `group_vars`.
5. **Preparar backups**: directorio, script, unidad `oneshot` y timer systemd.

---

## Plantillas `templates/` `.j2`

| Fichero `.j2` | Destino en el nodo | Qué hace |
|---|---|---|
| `conf.d-supply.conf.j2` | `/etc/postgresql/<ver>/main/conf.d/supply.conf` | Drop-in de configuración: fija `listen_addresses` y el puerto. Mantiene el `postgresql.conf` original intacto. |
| `pg_hba.conf.j2` | `/etc/postgresql/<ver>/main/pg_hba.conf` | Reglas de autenticación: «peer» para local, `scram-sha-256` para 127.0.0.1 y para la **única** red autorizada (data-net). |
| `backup_ecommerce.sh.j2` | `/usr/local/bin/backup_ecommerce.sh` | Script de backup: `pg_dump` → `gzip` → cifrado GPG **AES-256** → retención de `backup_retention_days`. |
| `ecommerce-backup.service.j2` | `/etc/systemd/system/ecommerce-backup.service` | Unidad systemd `oneshot` que ejecuta el script de backup como usuario `postgres`. |
| `ecommerce-backup.timer.j2` | `/etc/systemd/system/ecommerce-backup.timer` | Timer systemd que lanza la unidad diariamente (02:30) con `Persistent=true` (si el nodo estaba apagado, lo ejecuta al arrancar). |

---

## Variables utilizadas

Definidas en `defaults/main.yml`, `group_vars/all.yml` y el vault:

| Variable | Origen | Uso |
|---|---|---|
| `postgresql_version` | defaults | Versión principal de PostgreSQL (estructura de directorio `/etc/postgresql/`). |
| `database_data_ip` | defaults | IP de escucha del servidor (interfaz data-net). |
| `database_app_network` | defaults | Rango desde el que se acepta la conexión de la app (data-net). |
| `postgresql_port` | `group_vars/all.yml` | Puerto del servidor. |
| `ecommerce_db_name/user/password` | `all.yml` + vault | Base/rol/usuario de la aplicación. |
| `backup_dir`, `backup_retention_days` | `all.yml` | Ubicación y retención de backups. |
| `gpg_backup_passphrase` | `all.yml` + vault | Frase de cifrado GPG de los backups. |