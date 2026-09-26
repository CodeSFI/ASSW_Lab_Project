# Rol `perimeter_lb`

Capa **perimetral** del suministro. Se aplica al host `lb`
(`lb-proxy-01` / `lb-proxy-cantabrico-01`) mediante el último play de
`ansible/site.yml`:

```yaml
- name: Suministro del perimetro (Nginx + WAF ModSecurity)
  hosts: lb
  become: true
  roles:
    - role: perimeter_lb
```

## Objetivo

Convertir el balanceador en el **punto de entrada único del perímetro**. Cubre
tres bloques de trabajo:

- **S1 · Nginx** — proxy inverso + balanceador hacia los nodos de aplicación.
- **S2 · TLS + WAF** — ModSecurity-nginx con OWASP CRS, certificado autofirmado
  con endurecimiento SSL y rate limiting.
- **S3 · Health-checks** — *health-checks pasivos* (`max_fails` /
  `fail_timeout`) y validación de sintaxis.

## Estructura

```
perimeter_lb/
├── defaults/
│   └── main.yml               # 30 variables, agrupadas por semana (S1/S2)
├── files/
│   └── modsec-load.conf       # directiva load_module del conector WAF
├── handlers/
│   └── main.yml               # restart nginx / reload nginx
├── tasks/
│   └── main.yml               # 26 tareas en 6 fases
└── templates/
    ├── nginx.conf.j2          # configuración global
    ├── ecommerce.conf.j2      # upstream, vhosts, TLS, rate limit
    └── modsecurity.conf.j2    # configuración base del motor WAF
```

---

## `defaults/main.yml`

### Semana 1 · Nginx: proxy inverso + balanceador

| Variable | Valor por defecto | Descripción |
|---|---|---|
| `nginx_listen_http_port` | `80` | Puerto HTTP. Solo redirige a HTTPS, nunca sirve contenido. |
| `nginx_listen_https_port` | `443` | Puerto HTTPS. Tráfico real. |
| `lb_method` | `round_robin` | `round_robin` (alterna A/B, fácil de verificar) o `least_conn`. |
| `perimeter_app_backends` | `[10.10.20.11, 10.10.20.12]` | Pool de nodos de aplicación en `app-net`. |
| `app_backend_port` | `"{{ app_http_port }}"` | Hereda `app_http_port` = `8080` de `group_vars/all.yml`. |
| `lb_max_fails` | `3` | Errores consecutivos antes de retirar el nodo del pool. |
| `lb_fail_timeout` | `10` | Segundos que el nodo permanece retirado. |
| `lb_proxy_connect_timeout` | `2` | Timeout de conexión al backend (s). |
| `lb_proxy_read_timeout` | `10` | Timeout de lectura del backend (s). |
| `lb_proxy_next_upstream` | `error timeout invalid_header http_500 http_502 http_503 http_504` | Condiciones de failover a otro backend. |

### Semana 2 · TLS

| Variable | Valor por defecto | Descripción |
|---|---|---|
| `tls_cert_dir` | `/etc/nginx/ssl` | Directorio del certificado (`0700 root:root`). |
| `tls_cert_cn` | `lb-proxy-cantabrico-01` | CN del certificado autofirmado. |
| `tls_cert_days` | `365` | Validez del certificado. |
| `tls_san` | `DNS:{{ tls_cert_cn}},IP:{{ lb_dmz_ip}}` + `IP:{{ lb_fip}}` | SAN con CN + IP de DMZ + FIP pública (si está definida en `group_vars/all.yml`). |
| `tls_protocols` | `TLSv1.2 TLSv1.3` | Sin TLSv1.0/1.1. |
| `tls_ciphers` | Suite ECDHE + GCM (Mozilla *intermedio*) | Sin RC4, 3DES ni cifrados estáticos. |
| `tls_session_cache` | `shared:SSL:10m` | Caché de sesiones TLS. |
| `tls_session_timeout` | `10m` | Timeout de sesión. |
| `hsts_max_age` | `63072000` | 2 años, con `includeSubDomains`. |

### Semana 2 · Rate limiting

| Variable | Valor por defecto | Descripción |
|---|---|---|
| `rate_limit_zone_name` | `ecommerce` | Nombre de la zona en memoria compartida. |
| `rate_limit_zone_size` | `10m` | Tamaño de la zona por IP de origen. |
| `rate_limit_rps` | `10` | Peticiones/segundo permitidas por IP. |
| `rate_limit_burst` | `20` | Ráfaga admitida por encima de la tasa. |

### Semana 2 · ModSecurity + OWASP CRS

| Variable | Valor por defecto | Descripción |
|---|---|---|
| `modsec_rule_engine` | `On` | `On` (bloquea) o `DetectionOnly` (solo registra). |
| `modsec_dir` | `/etc/nginx/modsecurity` | Árbol de configuración del WAF. |
| `modsec_load_conf` | `/etc/nginx/modules-enabled/50-modsecurity.conf` | Fichero con la directiva `load_module`. |
| `modsec_module_path` | `/etc/nginx/modules/ngx_http_modsecurity_module.so` | Módulo dinámico compilado por el rol. |
| `modsec_audit_log` | `/var/log/nginx/modsec_audit.log` | Log de auditoría (`0640 www-data:adm`). |
| `modsec_connector_repo` | `https://github.com/owasp-modsecurity/ModSecurity-nginx.git` | Conector oficial. |
| `modsec_connector_dir` | `/usr/local/src/ModSecurity-nginx` | Clon del conector. |
| `modsec_src_dir` | `/usr/local/src` | Directorio de compilación. |
| `crs_git_url` | `https://github.com/coreruleset/coreruleset.git` | OWASP Core Rule Set. |
| `crs_git_version` | `v4.0.0` | Versión **fijada** (reproducible). |
| `modsec_crs_dir` | `/etc/nginx/modsecurity/owasp-crs` | Clon del CRS. |
| `mgmt_net_cidr` | `10.10.99.0/24` | Única red (además de loopback) autorizada a ver `/nginx_status`. |
| `lb_dmz_ip` | `10.10.10.10` | IP fija del balanceador en `dmz-net` (se incluye en el SAN). |

### Paquetes

`perimeter_apt_packages` instala:

- **Servicio:** `nginx`
- **Librería WAF:** `libmodsecurity3`, `libmodsecurity-dev`
- **Toolchain del conector:** `build-essential`, `pkg-config`, `libpcre2-dev`,
  `zlib1g-dev`, `libssl-dev`
- **Utilidades:** `git`, `curl`, `openssl`

> El conector `ModSecurity-nginx` **no** viene empaquetado en Ubuntu: el rol lo
> compila dinámicamente. La primera ejecución necesita salida a `nginx.org`,
> `github.com` y `apt`.

---

## `tasks/main.yml`

### Fase 0 · Paquetes y servicio

| Tarea | Detalle |
|---|---|
| Instalar paquetes del perímetro | `apt` con `perimeter_apt_packages` y `update_cache: true`. |
| Arrancar y habilitar nginx | `systemd`: `enabled: true`, `state: started`. |

### Fase 1 · Certificado TLS (S2)

1. Crea `{{ tls_cert_dir }}` con modo `0700 root:root`.
2. Genera clave RSA-2048 y certificado autofirmado SHA-256 con
   `openssl req -x509 -nodes -newkey rsa:2048`, incluyendo
   `-addext "subjectAltName={{ tls_san }}"`.
   **Idempotente** gracias a `creates: {{ tls_cert_dir }}/cantabrico.crt` y
   `notify: restart nginx`.

> **Para regenerar el certificado** (cambiar CN, SAN o validez) hay que borrar
> primero los ficheros; si no, la tarea se salta por completo:
> `rm -f /etc/nginx/ssl/cantabrico.{crt,key}` y relanzar el playbook.

### Fase 2 · Compilación del módulo ModSecurity-nginx (S2, solo 1.ª vez)

Todo el bloque está condicionado a `when: not modsec_module.stat.exists`
(`stat` sobre `modsec_module_path`).

| Tarea | Detalle |
|---|---|
| `¿Existe ya el modulo dinamico?` | `stat` → `modsec_module` |
| Detectar versión de nginx | `nginx -v`, con `changed_when: false` |
| Normalizar versión | `set_fact` + `regex_replace` → `1.27.4` a partir de `nginx/1.27.4` |
| Descargar fuentes de nginx | `get_url` desde `nginx.org/download/nginx-<ver>.tar.gz` |
| Clonar el conector | `git` con `depth: 1` |
| **S2a** Extraer fuentes | `unarchive` con `remote_src: true` |
| **S2b** Configurar | `./configure --with-compat --add-dynamic-module=<conector>` |
| **S2c** Compilar | `make modules -j{{ ansible_processor_vcpus | default(2) }}` |
| Crear directorio de módulos | `{{ modsec_module_path | dirname }}` con modo `0755` |
| Instalar el `.so` | `copy` con `remote_src: true` → `notify: restart nginx` |
| Desplegar `load_module` | `copy` de `files/modsec-load.conf` → `{{ modsec_load_conf }}` |

Claves del diseño:

- `--with-compat` es **imprescindible**: sin él el módulo compilado es
  binariamente incompatible con el nginx de la distribución.
- Se compila contra **la misma versión** de nginx ya instalada, de ahí que se
  detecte con `nginx -v` y se descargue el tarball correspondiente.
- La compilación solo ocurre una vez; en ejecuciones posteriores el `stat` la
  omite por completo.

### Fase 3 · OWASP CRS y motor ModSecurity (S2)

| Tarea | Detalle |
|---|---|
| Crear árbol de ModSecurity | `{{ modsec_dir }}` con modo `0755`. |
| Clonar OWASP CRS | `git` con `version: {{ crs_git_version }}` (fija = reproducible). |
| Activar `crs-setup.conf` | `copy` desde `crs-setup.conf.example` con `remote_src: true`. |
| Desplegar configuración base | `template: modsecurity.conf.j2` → `{{ modsec_dir }}/modsecurity.conf`. |
| Fijar modo del WAF | `lineinfile` con `regexp: ^SecRuleEngine\s+\S+` → `SecRuleEngine {{ modsec_rule_engine }}`. |
| Activar CRS en el motor | `blockinfile` con marcador, añade los dos `Include` (`crs-setup.conf` y `rules/*.conf`). |
| Crear fichero de auditoría | `file: state=touch`, `0640`, `www-data:adm`. |

> El `blockinfile` usa el marcador
> `# {mark} ANSIBLE perimeter_lb - OWASP CRS`. Si se edita el bloque a mano,
> Ansible lo restaura en la siguiente ejecución. No borrar el marcador.

### Fase 4 · Configuración de nginx y validación

| Tarea | Detalle |
|---|---|
| Desplegar `nginx.conf` principal | `template` → `/etc/nginx/nginx.conf` — `notify: reload nginx`. |
| Desplegar sitio `ecommerce` | `template` → `/etc/nginx/conf.d/ecommerce.conf` — `notify: reload nginx`. |
| **Validar sintaxis** | `nginx -t` con `changed_when: false` y `failed_when: nginx_test.rc != 0`. |

> La validación es **explícita y posterior** al despliegue (no se usa el
> parámetro `validate` del módulo `template`). Así una configuración inválida
> **falla el play antes** de que los handlers apliquen el `reload`, dejando nginx
> sirviendo con la configuración anterior.

### Fase 5 · Ruteo multihomed (ECMP) — crítico

El balanceador tiene **dos** interfaces conectadas al router: `dmz-net`
(10.10.10.10) y `mgmt-net` (10.10.99.10). Esto genera dos rutas por defecto y el
tráfico hacia los nodos app puede salir indistintamente por cualquiera.

El grupo de seguridad `sg-internal` **solo** permite el puerto 8080 desde la
subred DMZ, por lo que un flujo originado en la IP de gestión se descarta.

Solución en tres tareas:

1. **Identificar la interfaz de gestión** — recorre `ansible_facts.interfaces` y
   se queda con la que tenga una IPv4 que case con `^10\.10\.99\.` → `mgmt_iface`.
2. **Netplan** — escribe `/etc/netplan/99-mgmt-no-default.yaml` con
   `dhcp4-overrides: use-routes: false` para que la NIC de gestión no instale
   ruta por defecto (`0600 root:root`).
3. **`netplan apply`** — solo si el fichero anterior cambió.

> El prefijo `99-` garantiza que este fichero se aplique **después** del
> `/etc/netplan/50-cloud-init.yaml` generado por OpenStack, sobreescribiendo su
> ruta por defecto. `netplan apply` puede cortar brevemente la conexión de gestión.

---

## `handlers/main.yml`

| Handler | Acción | Notificado por |
|---|---|---|
| `restart nginx` | `systemd: state=restarted` | Generación del certificado, instalación del `.so` |
| `reload nginx` | `systemd: state=reloaded` | Despliegues de plantillas, `SecRuleEngine`, `blockinfile` del CRS |

Los handlers se ejecutan **al final del play**, no inmediatamente, por lo que un
`reload` agrupado es más eficiente que uno por tarea.

---

## `templates/`

### `nginx.conf.j2` → `/etc/nginx/nginx.conf`

Configuración global mínima y deliberadamente restrictiva:

- `user www-data`, `worker_processes auto`, `worker_connections 1024`.
- `include /etc/nginx/modules-enabled/*.conf` — punto de entrada de los módulos
  dinámicos (donde se inyecta ModSecurity).
- **`server_tokens off`** — no revela la versión de nginx.
- `client_max_body_size 16m`.
- `log_format main` incluyendo `X-Forwarded-For`; `error_log` en nivel `warn`.
- `include /etc/nginx/conf.d/*.conf` — el vhost vive en el `conf.d`.

### `ecommerce.conf.j2` → `/etc/nginx/conf.d/ecommerce.conf`

Contiene cuatro bloques:

**a) Zona de rate limiting** (contexto `http`)

```nginx
limit_req_zone $binary_remote_addr zone=ecommerce:10m rate=10r/s;
```

**b) Pool de backends** — `upstream ecommerce_backend`

- `least_conn;` solo si `lb_method == 'least_conn'` (condicional Jinja).
- Un `server <ip>:<puerto> max_fails=3 fail_timeout=10s;` por elemento de
  `perimeter_app_backends`.
- `keepalive 32`.

**c) Servidor HTTP (puerto 80)** — nunca sirve contenido en claro:

```nginx
return 301 https://$host$request_uri;
```

**d) Servidor HTTPS (puerto 443)** — terminación TLS, WAF, cabeceras y proxy:

- `listen 443 ssl` + `http2 on` (requiere nginx ≥ 1.25.1).
- Directivas `ssl_*` alimentadas desde `defaults` (protocolos, ciphers, sesión).
- `modsecurity on;` + `modsecurity_rules_file {{ modsec_dir }}/modsecurity.conf;`
- Cabeceras de endurecimiento con `always`: `Strict-Transport-Security`,
  `X-Content-Type-Options: nosniff`, `X-Frame-Options: DENY`,
  `Referrer-Policy: strict-origin-when-cross-origin`,
  `Content-Security-Policy: default-src 'self'`.
- `location = /healthz` — sonda local, `access_log off`, devuelve `200 "LB OK"`.
- `location = /nginx_status` — `stub_status` restringido a `127.0.0.1` y
  `{{ mgmt_net_cidr }}`, con `deny all`.
- `location /` — `limit_req ... burst=20 nodelay` + `proxy_pass` con `Host`,
  `X-Real-IP`, `X-Forwarded-For`, `X-Forwarded-Proto`, timeouts y
  `proxy_next_upstream`.

### `modsecurity.conf.j2` → `{{ modsec_dir }}/modsecurity.conf`

Configuración base del motor WAF. Sustituye a
`/etc/modsecurity/modsecurity.conf`, que `libmodsecurity3` ya no empaqueta en
Ubuntu 26.04.

- `SecRuleEngine DetectionOnly` como valor inicial, corregido después por
  `lineinfile` con `modsec_rule_engine`.
- `SecRequestBodyAccess On`, límite de 12,5 MB (`13107200`).
- `SecResponseBodyAccess Off`.
- `SecAuditEngine RelevantOnly` con regex `^(?:5|4(?!04))` y
  `SecAuditLogParts ABIJDEFHZ`.

> **Nota upstream**: con `libmodsecurity 3.0.14` el fichero de auditoría puede
> quedar vacío (regresión *SharedFiles*, `SpiderLabs/ModSecurity#3402`). Los
> bloqueos del WAF se registran igualmente en el `error.log` de nginx.

### `files/modsec-load.conf` → `{{ modsec_load_conf }}`

```nginx
load_module /etc/nginx/modules/ngx_http_modsecurity_module.so;
```

Usa **ruta absoluta** a propósito: el *prefix* de nginx en Ubuntu es
`/usr/share/nginx` y el módulo vive en `/etc/nginx/modules`, fuera de ese árbol.
nginx 1.27 ignora rutas relativas en `load_module`.

---

## Rutas y permisos

| Ruta | Propietario / Modo | Contenido |
|---|---|---|
| `/etc/nginx/ssl/` | `root:root` `0700` | Certificado y clave autofirmados |
| `/etc/nginx/ssl/cantabrico.{crt,key}` | — | Par RSA-2048 / SHA-256, 365 días |
| `/etc/nginx/modules/ngx_http_modsecurity_module.so` | `root:root` `0644` | Módulo dinámico compilado |
| `/etc/nginx/modules-enabled/50-modsecurity.conf` | `root:root` `0644` | Directiva `load_module` |
| `/etc/nginx/modsecurity/modsecurity.conf` | `root:root` `0644` | Motor WAF + `Include` del CRS |
| `/etc/nginx/modsecurity/owasp-crs/` | — | Clon del CRS v4.0.0 |
| `/var/log/nginx/modsec_audit.log` | `www-data:adm` `0640` | Auditoría del WAF |
| `/etc/netplan/99-mgmt-no-default.yaml` | `root:root` `0600` | Sin ruta por defecto en la NIC de gestión |

---

## Ejecución

```bash
# Solo el perímetro
ansible-playbook -i inventory.ini site.yml --ask-vault-pass --limit lb

# Sintaxis y estado
ansible lb -i inventory.ini -m shell -a "nginx -t && systemctl is-active nginx"
```

## Verificación

```bash
# 1. Módulo WAF realmente cargado
ansible lb -i inventory.ini -m shell -a "ls -l /etc/nginx/modules/ && grep -c modsecurity /etc/nginx/nginx.conf"

# 2. Sonda del balanceador
curl -k https://<lb_fip>/healthz          # -> LB OK

# 3. Redirección HTTP -> HTTPS
curl -kI http://<lb_fip>/                 # -> 301 https://...

# 4. Cabeceras de endurecimiento
curl -kI https://<lb_fip>/                # -> HSTS, X-Frame-Options, CSP...

# 5. Rate limiting (10 r/s, burst 20) — debe aparecer 503
for i in $(seq 1 60); do curl -sk -o /dev/null -w "%{http_code}\n" https://<lb_fip>/; done | sort | uniq -c

# 6. WAF bloqueando SQLi — debe devolver 403
curl -k "https://<lb_fip>/?id=1%20OR%201=1--"

# 7. Estadísticas del pool (solo local o desde MGMT)
curl -k https://<lb_fip>/nginx_status

# 8. Ruta de salida: debe ser por la DMZ, no por la de gestión
ansible lb -i inventory.ini -m shell -a "ip route get 10.10.20.11"   # -> via 10.10.10.1 dev <dmz_iface>

# 9. Balanceo round-robin (alterna A/B entre los dos nodos)
for i in 1 2 3 4; do curl -ks https://<lb_fip>/ | grep -i 'node\|server'; done
```

---

## Notas de mantenimiento y puntos de atención

1. **Versión de nginx.** `ecommerce.conf.j2` usa `http2 on;`, que **requiere
   nginx ≥ 1.25.1**. Los comentarios de las plantillas citan *Ubuntu 26.04*,
   mientras que `AGENTS.md` documenta *Ubuntu 22.04* como imagen base (nginx
   1.18/1.24, que no soporta esa directiva y usaría `listen ... http2`). Hay que
   **alinear la imagen base con lo que el rol espera** o cambiar la directiva
   según la versión de nginx desplegada.

2. **Certificado autofirmado idempotente.** El `creates:` implica que cambiar
   `tls_cert_cn`, `tls_san` o `tls_cert_days` **no** regenera nada hasta borrar
   `cantabrico.crt` y `cantabrico.key`.

3. **Backends hardcodeados.** `perimeter_app_backends` contiene las IP fijas de
   `app-net` (10.10.20.11/12) definidas en Terraform, **no** las IP de gestión
   del inventario (10.10.99.21/22). Es intencionado: el grupo de seguridad solo
   permite 8080 desde la subred DMZ.

4. **`tls_san` depende de `lb_fip`**, definida en `group_vars/all.yml`. Si se
   recrea la infraestructura hay que actualizar `bastion_fip` y `lb_fip`, o el
   SAN quedará desactualizado.

5. **Salida a Internet** obligatoria en la primera ejecución (apt, `nginx.org`,
   `github.com`). Sin ella el rol falla en la fase de compilación.

6. **Modo del WAF.** `On` (bloquea) es el valor por defecto de
   `modsec_rule_engine`; `DetectionOnly` solo registra. Para revisar eventos:
   `/var/log/nginx/error.log`.

7. **Auditoría del WAF** puede quedar vacía por la regresión conocida de
   libmodsecurity 3.0.14; los eventos siguen apareciendo en el `error.log`.

8. **Orden de los handlers.** Al ejecutarse al final del play, un fallo en
   `nginx -t` aborta antes del `reload`, dejando la configuración anterior
   sirviendo tráfico. Es el comportamiento deseado.
