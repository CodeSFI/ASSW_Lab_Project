# Integrante 2 — Perímetro, WAF y Alta Disponibilidad Web

**Guía de implementación paso a paso** del nodo perimetral `lb-proxy-cantabrico-01`.

Documento de trabajo para poder decir con seguridad: **«mi parte está hecha»**.
Sigue el plan del proyecto (`docs/definición_inicial_proyecto.md`) y las
convenciones ya usadas por los roles `app_node` y `database`.

---

## Resumen de lo que cubre (por semana)

| Semana | Entregable | Ficheros implicados |
|---|---|---|
| **S1** | Rol de Ansible `perimeter_lb` + Nginx como proxy inverso y balanceador hacia los nodos de aplicación | `roles/perimeter_lb/**`, `site.yml`, `group_vars/all.yml` |
| **S2** | ModSecurity + OWASP CRS, certificado TLS con endurecimiento SSL (ciphers, HSTS) y políticas de rate limiting | `tasks/main.yml`, `templates/ecommerce.conf.j2`, `files/modsec-load.conf` |
| **S3** | Verificación de balanceo ante caídas de nodos (health-checks) y pruebas de bloqueo de vectores OWASP | `scripts/test_security.sh` (opcional) |

> **No hace falta acceso a las máquinas para leer esta guía**: la infra ya está
> desplegada con Terraform. La documentación asume que el *control node* tiene
> Ansible y puede saltar por el bastión (así está configurado el repo).

---

## 0. Contexto y prerrequisitos

### 0.1 Dónde encaja esta parte en la arquitectura

```text
                    INTERNET
                       │
              [FIP balanceador 80/443]
                       │
┌──────────────────────▼──────────────────────────┐
│  lb-proxy-cantabrico-01   (dmz-net 10.10.10.10) │
│  Nginx (proxy inverso + LB)                     │
│  ModSecurity + OWASP CRS (WAF)                  │
│  Terminación TLS + Rate limiting                │
└──────────────────────┬──────────────────────────┘
                       │ HTTP/8080 (balanceado)
        ┌──────────────▼──────────────┐
        │ app-net 10.10.20.0/24       │
        │ app01 10.10.20.11 :8080     │
        │ app02 10.10.20.12 :8080     │
        └─────────────────────────────┘
```

Tabla de referencia de IPs (del `terraform/` y `ansible/inventory.ini`):

| Host | IP DMZ | IP MGMT | Rol |
|---|---|---|---|
| `lb-proxy-01` (`lb-proxy-cantabrico-01`) | 10.10.10.10 | 10.10.99.10 | Balanceador / WAF (este rol) |
| `app-node-01` | — | 10.10.99.21 | Mock API 10.10.20.11:8080 |
| `app-node-02` | — | 10.10.99.22 | Mock API 10.10.20.12:8080 |
| `bastion-ops-01` | — | 10.10.99.20 (FIP) | Salto SSH (ProxyJump) |

### 0.2 Qué ya existe en el repo (no hay que rehacerlo)

- `terraform/` → infraestructura completa (SGs ya permiten **80/443 desde
  `0.0.0.0/0`** hacia el LB y **8080 desde dmz-net** hacia los app-nodes; ver
  `security_groups.tf` → `sg-lb` y regla `app_http_from_dmz`).
- `ansible/inventory.ini` → grupo `[lb]` con `ansible_host=10.10.99.10`.
- `ansible/ansible.cfg` + `group_vars/all.yml` → salto por el bastión
  (`ansible_ssh_common_args` con `ProxyCommand`) y `app_http_port: 8080`.
- `roles/app_node` (Integrante 3) → mock HTTP en `:8080` con `/health` y
  cabecera JSON `"host"` que identifica el nodo (clave para los tests de
  balanceo).

### 0.3 Prerrequisitos en el control node

```bash
# (una sola vez, igual que el resto del equipo)
sudo apt install -y python3 python3-pip
sudo pip install "ansible>=2.15"
cd ansible
ansible-galaxy collection install -r requirements.yml

# Clave maestra de Vault fuera del repo (si no la tienes aún)
printf '%s' 'LA_FRASE_MAESTRA_DEL_EQUIPO' > ~/.ansible_vault_pass_cantabrico
chmod 600 ~/.ansible_vault_pass_cantabrico
```

> Ninguna colección nueva: este rol usa solo módulos *builtin* de Ansible
> (`apt`, `systemd`, `template`, `copy`, `command`, `get_url`, `git`, …) y
> herramientas que se instalan **en el propio LB** (nginx, openssl, git…).

### 0.4 Verificar conectividad con el nodo perimetral

```bash
cd ansible
ansible lb -m ping
```

Esperado: `pong` en `lb-proxy-01` (a través del bastión). Si da timeout,
revisar que `bastion_fip` en `group_vars/all.yml` es la FIP real del bastión.

> **Coordinación con Integrante 1 (dependencia para S3):** el balanceador
> necesita una **IP flotante asociada al puerto DMZ** (`cantabrico-port-lb-dmz`)
> para poder probar el WAF desde Internet. Hoy `terraform/` solo asocia FIP al
> bastión. En §6 hay un snippet opcional para añadirla (o asociarla a mano en
> Horizon: Compute → Floating IPs → Associate → `cantabrico-port-lb-dmz`).

---

## 1. Semana 1 — Rol `perimeter_lb` + Nginx (proxy inverso y balanceador)

### 1.1 Estructura del rol

```text
ansible/roles/perimeter_lb/
├── defaults/
│   └── main.yml          # variables del rol
├── handlers/
│   └── main.yml          # reload/restart de nginx
├── tasks/
│   └── main.yml          # lógica: S1 instala/arranca nginx y despliega conf
├── templates/
│   ├── nginx.conf.j2     # nginx.conf principal (hardening básico)
│   └── ecommerce.conf.j2 # upstream + server 80 (v1 en S1; TLS/WAF en S2)
└── files/
    └── modsec-load.conf  # (se crea en S2) directiva load_module
```

### 1.2 `roles/perimeter_lb/defaults/main.yml`

Versión mínima necesaria para S1 (en S2 se amplía):

```yaml
---
# Variables del rol perimeter_lb (capa perimetral, Integrante 2).

# --- Semana 1 · Nginx: proxy inverso + balanceador ---------------------------
nginx_listen_http_port: 80
nginx_listen_https_port: 443

# Metodo de balanceo: round_robin (alterna A/B, facil de verificar) | least_conn
lb_method: round_robin

# Backends: nodos de aplicacion (red de aplicacion 10.10.20.0/24).
perimeter_app_backends:
  - "10.10.20.11"
  - "10.10.20.12"

# Puerto donde escucha el mock en los backends (definido en all.yml).
app_backend_port: "{{ app_http_port }}"

# Health-checks pasivos de Nginx (open source): tras max_fails errores
# consecutivos un nodo se retira del pool durante fail_timeout segundos.
lb_max_fails: 3
lb_fail_timeout: 10
lb_proxy_connect_timeout: 2
lb_proxy_read_timeout: 10
lb_proxy_next_upstream: error timeout invalid_header http_500 http_502 http_503 http_504

# Paquetes base (S1). En S2 se amplian con las dependencias de ModSecurity.
perimeter_apt_packages:
  - nginx
  - curl
  - openssl
```

### 1.3 `roles/perimeter_lb/handlers/main.yml`

```yaml
---
# Handlers del rol perimeter_lb
- name: restart nginx
  ansible.builtin.systemd:
    name: nginx
    state: restarted

- name: reload nginx
  ansible.builtin.systemd:
    name: nginx
    state: reloaded
```

### 1.4 `roles/perimeter_lb/tasks/main.yml` (Semana 1)

```yaml
---
# Rol: perimeter_lb
# Objetivo (Integrante 2): convertir lb-proxy-cantabrico-01 en el punto de
# entrada unico del perimetro:
#   S1 · Nginx como proxy inverso + balanceador hacia los app-nodes.
#   S2 · ModSecurity + OWASP CRS, TLS autofirmado con endurecimiento SSL y
#       politicas de rate limiting.
#   S3 · Health-checks pasivos (max_fails/fail_timeout) + verificacion.

- name: "S1 · Instalar paquetes del perimetro"
  ansible.builtin.apt:
    name: "{{ perimeter_apt_packages }}"
    state: present
    update_cache: true

- name: "S1 · Arrancar y habilitar nginx"
  ansible.builtin.systemd:
    name: nginx
    enabled: true
    state: started

# ------------------------- Semanas 1 y 2 · configuracion ---------------------
- name: "S1 · Desplegar nginx.conf principal"
  ansible.builtin.template:
    src: nginx.conf.j2
    dest: /etc/nginx/nginx.conf
    mode: "0644"
  notify: reload nginx

- name: "S1/S2 · Desplegar sitio ecommerce (upstreams + balanceo)"
  ansible.builtin.template:
    src: ecommerce.conf.j2
    dest: /etc/nginx/conf.d/ecommerce.conf
    mode: "0644"
  notify: reload nginx

- name: "S3 · Validar sintaxis de la configuracion"
  ansible.builtin.command: nginx -t
  register: nginx_test
  changed_when: false
  failed_when: nginx_test.rc != 0
```

### 1.5 `roles/perimeter_lb/templates/nginx.conf.j2`

```nginx
# nginx.conf gestionado por el rol perimeter_lb (Integrante 2).
user www-data;
worker_processes auto;
pid /run/nginx.pid;

# Carga de modulos dinamicos (en S2 se anade el conector ModSecurity-nginx).
include /etc/nginx/modules-enabled/*.conf;

events {
    worker_connections 1024;
}

http {
    include /etc/nginx/mime.types;
    default_type application/octet-stream;

    sendfile on;
    tcp_nopush on;
    keepalive_timeout 65;
    server_tokens off;                 # no revelar version de nginx

    client_max_body_size 16m;

    log_format main '$remote_addr - $remote_user [$time_local] "$request" '
                    '$status $body_bytes_sent "$http_referer" '
                    '"$http_user_agent" "$http_x_forwarded_for"';
    access_log /var/log/nginx/access.log main;
    error_log /var/log/nginx/error.log warn;

    include /etc/nginx/conf.d/*.conf;
}
```

### 1.6 `roles/perimeter_lb/templates/ecommerce.conf.j2` (versión Semana 1)

Sin TLS/WAF todavía, para poder probar el balanceo por HTTP:

```nginx
# ecommerce.conf — Perimetro (Integrante 2) — VERSION S1 (sin TLS/WAF)
# Gestionado por Ansible (rol perimeter_lb); NO editar a mano.

# Pool de backends: nodos de aplicacion (app-net).
# Health-checks pasivos: max_fails + fail_timeout retiran nodos caidos.
upstream ecommerce_backend {
{% if lb_method == 'least_conn' %}
    least_conn;
{% endif %}
{% for backend in perimeter_app_backends %}
    server {{ backend }}:{{ app_backend_port }} max_fails={{ lb_max_fails }} fail_timeout={{ lb_fail_timeout }}s;
{% endfor %}
    keepalive 32;
}

server {
    listen {{ nginx_listen_http_port }};
    listen [::]:{{ nginx_listen_http_port }};
    server_name _;

    # Sonda de disponibilidad del propio balanceador.
    location = /healthz {
        access_log off;
        default_type text/plain;
        return 200 "LB OK\n";
    }

    # Proxy inverso + balanceo hacia el pool.
    location / {
        proxy_pass http://ecommerce_backend;
        proxy_http_version 1.1;
        proxy_set_header Connection "";
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;

        proxy_connect_timeout {{ lb_proxy_connect_timeout }}s;
        proxy_read_timeout {{ lb_proxy_read_timeout }}s;
        proxy_next_upstream {{ lb_proxy_next_upstream }};
    }
}
```

### 1.7 Integrar el rol en el playbook y en group_vars

**`ansible/site.yml`** — añadir un tercer play (después del de `app`):

```yaml
- name: Suministro del perimetro (Nginx + WAF ModSecurity)
  hosts: lb
  become: true
  roles:
    - role: perimeter_lb
```

**`ansible/group_vars/all.yml`** — añadir al final (variable no sensible,
la FIP la rellena quien gestione Terraform; si está vacía el certificado y los
mensajes simplemente no la usan):

```yaml
# -----------------------------------------------------------------------------
# Capa perimetral (Integrante 2): balanceador / WAF
# -----------------------------------------------------------------------------
# IP flotante publica del balanceador (asociada al puerto DMZ 10.10.10.10).
# Si Terraform aun no la asocia, ver seccion 6 de
# docs/integrante2-perimetro-waf.md (coordinacion con Integrante 1).
lb_fip: ""
```

### 1.8 Ejecutar la Semana 1

```bash
cd ansible
ansible-playbook -i inventory.ini site.yml --limit lb
```

Esperado en el `PLAY RECAP`: `ok` en `lb-proxy-01`, **0 failed/unreachable**.
Segunda ejecución: `changed=0` (idempotencia).

### 1.9 Verificación de la Semana 1

```bash
# 1) Servicio activo y habilitado
ansible lb -m shell -a "systemctl is-active nginx && systemctl is-enabled nginx"
#    Esperado: active / enabled

# 2) Localizador de prueba: FIP del LB, o 10.10.10.10 ejecutando desde el bastion
export LB=156.35.x.x          # o, si la FIP aun no existe: LB=10.10.10.10 (ssh bastion)
while true; do curl -s "http://$LB/products"; echo; sleep 1; done | grep '"host"'
#    Esperado: aparecen ALTERNANDO tanto "cantabrico-app-node-01" como
#    "cantabrico-app-node-02"  -> el balanceador reparte entre los 2 nodos

# 3) Sonda de disponibilidad del LB
curl -s "http://$LB/healthz"
#    Esperado: LB OK
```

> Si pruebas contra la IP interna 10.10.10.10, hazlo desde dentro del bastión
> (`ssh sysadmin_cantabrico@<FIP_BASTION>`) porque la DMZ no es alcanzable
> desde tu PC sin FIP.

---

## 2. Semana 2 — ModSecurity + OWASP CRS, TLS endurecido y Rate Limiting

### 2.0 Decisiones de diseño (léelas antes de copiar)

1. **ModSecurity en nginx**: Ubuntu **no empaqueta** un módulo de ModSecurity
   para nginx (el paquete `libmodsecurity3` es solo la librería). La forma
   estándar y reproducible es **compilar el conector `ModSecurity-nginx` como
   módulo dinámico** contra la **misma versión de nginx instalada**. El rol lo
   hace solo la primera vez (guarda el `.so` en `/etc/nginx/modules/`).
2. **OWASP CRS**: se clona de GitHub a una **versión fija** (`v4.0.0`) para que
   el despliegue sea reproducible, y se activa incluyendo `crs-setup.conf` +
   `rules/*.conf` desde la configuración del motor.
3. **TLS**: certificado **autofirmado generado en el propio nodo** (sin
   secretos en el repo ni en el vault). Los SANs incluyen la IP de la DMZ y la
   FIP (si existe). Endurecimiento: solo `TLSv1.2`/`TLSv1.3`, ciphers seguros
   (Mozilla intermediate) y cabecera HSTS.
4. **Rate limiting**: zona `limit_req_zone` por IP de origen en el contexto
   `http` y directiva `limit_req` en la ubicación de proxy.

### 2.1 Ampliar `defaults/main.yml` (añadir tras lo de S1)

```yaml
# --- Semana 2 · TLS ----------------------------------------------------------
tls_cert_dir: /etc/nginx/ssl
tls_cert_cn: lb-proxy-cantabrico-01
tls_cert_days: 365
# SAN: CN + IP de la DMZ + (si esta definida) la FIP publica del balanceador.
tls_san: "DNS:{{ tls_cert_cn }},IP:{{ lb_dmz_ip }}{{ ',IP:' ~ lb_fip if lb_fip | default('') | length > 0 else '' }}"
tls_protocols: "TLSv1.2 TLSv1.3"
# Ciphers seguros (nivel 'intermedio' de Mozilla); sin TLSv1.0/1.1, RC4, 3DES.
tls_ciphers: >-
  ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:
  ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384:
  ECDHE-ECDSA-CHACHA20-POLY1305:ECDHE-RSA-CHACHA20-POLY1305:
  DHE-RSA-AES128-GCM-SHA256:DHE-RSA-AES256-GCM-SHA384
tls_session_cache: "shared:SSL:10m"
tls_session_timeout: 10m
hsts_max_age: 63072000        # 2 anos, con includeSubDomains

# --- Semana 2 · Rate limiting -----------------------------------------------
rate_limit_zone_name: ecommerce
rate_limit_zone_size: 10m
rate_limit_rps: 10            # peticiones/segundo permitidas por IP
rate_limit_burst: 20          # rafaga admitida por encima de la tasa

# --- Semana 2 · ModSecurity + OWASP CRS --------------------------------------
modsec_rule_engine: On        # On (bloquea) | DetectionOnly (solo registra)
modsec_dir: /etc/nginx/modsecurity
modsec_load_conf: /etc/nginx/modules-enabled/50-modsecurity.conf
modsec_module_path: /etc/nginx/modules/ngx_http_modsecurity_module.so
modsec_audit_log: /var/log/nginx/modsec_audit.log
modsec_connector_repo: https://github.com/owasp-modsecurity/ModSecurity-nginx.git
modsec_connector_dir: /usr/local/src/ModSecurity-nginx
modsec_src_dir: /usr/local/src
crs_git_url: https://github.com/coreruleset/coreruleset.git
crs_git_version: v4.0.0       # version fijada (reproducible); se puede subir
modsec_crs_dir: /etc/nginx/modsecurity/owasp-crs
mgmt_net_cidr: "10.10.99.0/24"

# IP fija del balanceador en dmz-net (para el SAN del certificado).
lb_dmz_ip: "10.10.10.10"

# Paquetes: S1 + dependencias para compilar el conector ModSecurity-nginx.
perimeter_apt_packages:
  - nginx
  - build-essential
  - libpcre2-dev
  - zlib1g-dev
  - libssl-dev
  - libmodsecurity3
  - libmodsecurity-dev
  - git
  - curl
  - openssl
```

### 2.2 Añadir `roles/perimeter_lb/files/modsec-load.conf`

Contenido (directiva de carga del módulo dinámico, se copia a
`/etc/nginx/modules-enabled/` que es el punto de inclusión del nginx de Ubuntu):

```nginx
# Modulo dinamico ModSecurity-nginx (compilado por el rol perimeter_lb).
load_module modules/ngx_http_modsecurity_module.so;
```

### 2.3 Ampliar `tasks/main.yml` — TLS

Añadir estas tareas (después del arranque de nginx, antes de desplegar la
configuración):

```yaml
# ------------------------- Semana 2 · certificado TLS ------------------------
- name: "S2 · Crear directorio de certificados"
  ansible.builtin.file:
    path: "{{ tls_cert_dir }}"
    state: directory
    mode: "0700"
    owner: root
    group: root

- name: "S2 · Generar clave privada + certificado autofirmado (idempotente)"
  ansible.builtin.command: >-
    openssl req -x509 -nodes -newkey rsa:2048 -sha256 -days {{ tls_cert_days }}
    -keyout {{ tls_cert_dir }}/cantabrico.key
    -out {{ tls_cert_dir }}/cantabrico.crt
    -subj "/CN={{ tls_cert_cn }}" -addext "subjectAltName={{ tls_san }}"
  args:
    creates: "{{ tls_cert_dir }}/cantabrico.crt"
  notify: restart nginx
```

> `-addext` requiere OpenSSL ≥ 1.1.1 (Ubuntu 26.04 trae OpenSSL 3.x). La clave
> **solo se genera una vez** (`creates`) y queda en `/etc/nginx/ssl` con
> permisos `0700` (no viaja al repo).

### 2.4 Ampliar `tasks/main.yml` — compilar el conector ModSecurity-nginx

```yaml
# --------------- Semana 2 · conector ModSecurity-nginx (solo 1a vez) ---------
- name: "S2 · ¿Existe ya el modulo dinamico?"
  ansible.builtin.stat:
    path: "{{ modsec_module_path }}"
  register: modsec_module

- name: "S2 · Detectar version de nginx instalada"
  ansible.builtin.command: nginx -v
  register: nginx_v
  changed_when: false
  when: not modsec_module.stat.exists

- name: "S2 · Normalizar version (de 'nginx/1.27.4' a '1.27.4')"
  ansible.builtin.set_fact:
    nginx_version: "{{ nginx_v.stderr | regex_replace('^.*nginx/([0-9.]+).*$', '\\1') }}"
  when: not modsec_module.stat.exists

- name: "S2 · Descargar fuentes de nginx de la misma version"
  ansible.builtin.get_url:
    url: "https://nginx.org/download/nginx-{{ nginx_version }}.tar.gz"
    dest: "{{ modsec_src_dir }}/nginx-{{ nginx_version }}.tar.gz"
  when: not modsec_module.stat.exists

- name: "S2 · Clonar el conector ModSecurity-nginx"
  ansible.builtin.git:
    repo: "{{ modsec_connector_repo }}"
    dest: "{{ modsec_connector_dir }}"
    depth: 1
  when: not modsec_module.stat.exists

- name: "S2 · Compilar el modulo dinamico (configure + make modules)"
  ansible.builtin.block:
    - name: "S2a · Extraer fuentes de nginx"
      ansible.builtin.unarchive:
        src: "{{ modsec_src_dir }}/nginx-{{ nginx_version }}.tar.gz"
        dest: "{{ modsec_src_dir }}"
        remote_src: true

    - name: "S2b · Configurar con --with-compat y el conector"
      ansible.builtin.command: "./configure --with-compat --add-dynamic-module={{ modsec_connector_dir }}"
      args:
        chdir: "{{ modsec_src_dir }}/nginx-{{ nginx_version }}"
      changed_when: false

    - name: "S2c · Compilar los modulos dinamicos"
      ansible.builtin.command: "make modules -j{{ ansible_processor_vcpus | default(2) }}"
      args:
        chdir: "{{ modsec_src_dir }}/nginx-{{ nginx_version }}"
      changed_when: false
  when: not modsec_module.stat.exists

- name: "S2 · Instalar el modulo dinamico en nginx"
  ansible.builtin.copy:
    src: "{{ modsec_src_dir }}/nginx-{{ nginx_version }}/objs/ngx_http_modsecurity_module.so"
    dest: "{{ modsec_module_path }}"
    mode: "0644"
  when: not modsec_module.stat.exists
  notify: restart nginx

- name: "S2 · Desplegar directiva load_module del conector"
  ansible.builtin.copy:
    src: modsec-load.conf
    dest: "{{ modsec_load_conf }}"
    mode: "0644"
  notify: restart nginx
```

> Notas:
> - El nginx de Ubuntu trae `--with-compat`, por eso el módulo compilado con
>   `--with-compat` es ABI-compatible y se carga sin problemas.
> - La compilación tarda unos minutos la primera vez (el playbook lo avisa con
>   `changed` en esas tareas). En la 2ª ejecución todo queda en `ok/changed=0`.
> - Si el `.so` no cargara (`nginx -t` falla), problema casi siempre de
>   versiones: borrar el `.so` y re-ejecutar, o revisar §7 (troubleshooting).

### 2.5 Ampliar `tasks/main.yml` — OWASP CRS + motor ModSecurity

```yaml
# ------------------- Semana 2 · OWASP CRS + motor ModSecurity ----------------
- name: "S2 · Crear arbol de ModSecurity"
  ansible.builtin.file:
    path: "{{ modsec_dir }}"
    state: directory
    mode: "0755"

- name: "S2 · Clonar OWASP CRS (version fijada)"
  ansible.builtin.git:
    repo: "{{ crs_git_url }}"
    dest: "{{ modsec_crs_dir }}"
    version: "{{ crs_git_version }}"
    depth: 1

- name: "S2 · Activar crs-setup.conf (a partir del ejemplo)"
  ansible.builtin.copy:
    src: "{{ modsec_crs_dir }}/crs-setup.conf.example"
    dest: "{{ modsec_crs_dir }}/crs-setup.conf"
    remote_src: true
    mode: "0644"

- name: "S2 · Usar la configuracion base de libmodsecurity3"
  ansible.builtin.copy:
    src: /etc/modsecurity/modsecurity.conf
    dest: "{{ modsec_dir }}/modsecurity.conf"
    remote_src: true
    mode: "0644"

- name: "S2 · Fijar el modo del motor WAF (On / DetectionOnly)"
  ansible.builtin.lineinfile:
    path: "{{ modsec_dir }}/modsecurity.conf"
    regexp: "^SecRuleEngine\\s+\\S+"
    line: "SecRuleEngine {{ modsec_rule_engine }}"
    create: true
  notify: reload nginx

- name: "S2 · Activar OWASP CRS dentro del motor"
  ansible.builtin.blockinfile:
    path: "{{ modsec_dir }}/modsecurity.conf"
    marker: "# {mark} ANSIBLE perimeter_lb - OWASP CRS"
    block: |
      # OWASP Core Rule Set
      Include {{ modsec_crs_dir }}/crs-setup.conf
      Include {{ modsec_crs_dir }}/rules/*.conf
  notify: reload nginx

- name: "S2 · Crear fichero de auditoria del WAF"
  ansible.builtin.file:
    path: "{{ modsec_audit_log }}"
    state: touch
    mode: "0640"
    owner: www-data
    group: adm
```

> El resultado en `{{ modsec_dir }}/modsecurity.conf` es equivalente a:
>
> ```nginx
> # --- (configuracion base de libmodsecurity3) ---
> SecRuleEngine On
> ...
> # BEGIN ANSIBLE MANAGED BLOCK - perimeter_lb - OWASP CRS
> Include /etc/nginx/modsecurity/owasp-crs/crs-setup.conf
> Include /etc/nginx/modsecurity/owasp-crs/rules/*.conf
> # END ANSIBLE MANAGED BLOCK
> ```
>
> `rules/*.conf` solo incluye ficheros `.conf` reales (los de exclusión son
> `.conf.example`), así que el glob es seguro.

### 2.6 `templates/ecommerce.conf.j2` — versión final (Semana 2)

Reemplaza la versión S1 por esta (añade TLS, WAF, rate limiting y cabeceras):

```nginx
# ecommerce.conf — Perimetro (Integrante 2) — VERSION FINAL
# Proxy inverso + balanceador + TLS + WAF (ModSecurity) + rate limiting.
# Gestionado por Ansible (rol perimeter_lb); NO editar a mano.

# Zona de rate limiting (contexto http): por IP de origen.
limit_req_zone $binary_remote_addr zone={{ rate_limit_zone_name }}:{{ rate_limit_zone_size }} rate={{ rate_limit_rps }}r/s;

# Pool de backends: nodos de aplicacion (app-net 10.10.20.0/24).
# Health-checks pasivos: max_fails + fail_timeout retiran nodos caidos.
upstream ecommerce_backend {
{% if lb_method == 'least_conn' %}
    least_conn;
{% endif %}
{% for backend in perimeter_app_backends %}
    server {{ backend }}:{{ app_backend_port }} max_fails={{ lb_max_fails }} fail_timeout={{ lb_fail_timeout }}s;
{% endfor %}
    keepalive 32;
}

# -----------------------------------------------------------------------------
# Puerto 80: SOLO redireccion permanente a HTTPS (nunca se sirve en claro).
# -----------------------------------------------------------------------------
server {
    listen {{ nginx_listen_http_port }};
    listen [::]:{{ nginx_listen_http_port }};
    server_name _;
    return 301 https://$host$request_uri;
}

# -----------------------------------------------------------------------------
# Puerto 443: terminacion TLS + WAF + rate limiting + proxy al pool.
# -----------------------------------------------------------------------------
server {
    listen {{ nginx_listen_https_port }} ssl;
    listen [::]:{{ nginx_listen_https_port }} ssl;
    http2 on;                 # requiere nginx >= 1.25.1 (Ubuntu 26.04 OK)
    server_name _;

    # --- TLS (certificado autofirmado generado por el rol) ---
    ssl_certificate     {{ tls_cert_dir }}/cantabrico.crt;
    ssl_certificate_key {{ tls_cert_dir }}/cantabrico.key;
    ssl_protocols       {{ tls_protocols }};
    ssl_ciphers         "{{ tls_ciphers }}";
    ssl_prefer_server_ciphers on;
    ssl_session_cache   {{ tls_session_cache }};
    ssl_session_timeout {{ tls_session_timeout }};

    # --- WAF: ModSecurity-nginx + OWASP CRS ---
    modsecurity on;
    modsecurity_rules_file {{ modsec_dir }}/modsecurity.conf;

    # --- Cabeceras de endurecimiento ---
    add_header Strict-Transport-Security "max-age={{ hsts_max_age }}; includeSubDomains" always;
    add_header X-Content-Type-Options "nosniff" always;
    add_header X-Frame-Options "DENY" always;
    add_header Referrer-Policy "strict-origin-when-cross-origin" always;
    add_header Content-Security-Policy "default-src 'self'" always;

    # Sonda de disponibilidad del propio balanceador.
    location = /healthz {
        access_log off;
        default_type text/plain;
        return 200 "LB OK\n";
    }

    # Estadisticas del pool (solo local o desde la red de gestion).
    location = /nginx_status {
        stub_status;
        allow 127.0.0.1;
        allow {{ mgmt_net_cidr }};
        deny all;
    }

    # Proxy inverso + rate limiting hacia el pool ecommerce.
    location / {
        limit_req zone={{ rate_limit_zone_name }} burst={{ rate_limit_burst }} nodelay;

        proxy_pass http://ecommerce_backend;
        proxy_http_version 1.1;
        proxy_set_header Connection "";
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;

        proxy_connect_timeout {{ lb_proxy_connect_timeout }}s;
        proxy_read_timeout {{ lb_proxy_read_timeout }}s;
        proxy_next_upstream {{ lb_proxy_next_upstream }};
    }
}
```

> Si el nginx de la imagen fuera < 1.25.1, sustituir `http2 on;` por
> `listen 443 ssl http2;` (deprecated pero funcional). Con Ubuntu 26.04 no hace
> falta.

### 2.7 Ejecutar la Semana 2

```bash
cd ansible
ansible-playbook -i inventory.ini site.yml --limit lb
```

Esperado: primera ejecución compila el conector (`changed` en las tareas S2) y
termina con `nginx -t` en `ok` y **0 failed**. Segunda ejecución: `changed=0`.

### 2.8 Verificación de la Semana 2

```bash
export LB=156.35.x.x        # FIP del LB (o 10.10.10.10 desde el bastion)

# T2.1 Redireccion HTTP -> HTTPS
curl -sI "http://$LB/" | head -1
#    Esperado: HTTP/1.1 301 Moved Permanently (Location: https://...)

# T2.2 Certificado desplegado con su SAN (DMZ + FIP)
ssh sysadmin_cantabrico@<FIP_BASTION>
ssh sysadmin_cantabrico@10.10.99.10 "openssl x509 -in /etc/nginx/ssl/cantabrico.crt -noout -subject -text | grep -A1 'Subject Alternative Name'"
#    Esperado: DNS:lb-proxy-cantabrico-01, IP:10.10.10.10, IP:<FIP_LB>

# T2.3 Solo TLSv1.2/1.3 (TLSv1.0/1.1 deben FALLAR)
echo | openssl s_client -connect "$LB:443" -tls1_2 </dev/null 2>/dev/null | grep "Cipher is"
#    Esperado: cipher negociado (p. ej. ECDHE-RSA-AES128-GCM-SHA256)
echo | openssl s_client -connect "$LB:443" -tls1 </dev/null 2>/dev/null | grep -i "alert\|error" || echo "TLSv1.0 RECHAZADO (OK)"

# T2.4 Cabeceras de endurecimiento (HSTS + seguridad)
curl -skI "https://$LB/" | grep -iE "strict-transport-security|x-content-type-options|x-frame-options|content-security-policy"
#    Esperado: las 4 cabeceras presentes (HSTS: max-age=63072000; includeSubDomains)

# T2.5 El conector ModSecurity esta cargado
ansible lb -m shell -a "nginx -T 2>/dev/null | grep -i modsecurity | head -3"
#    Esperado: lines como "modsecurity on;" y "# load_module ..." no; busca:
#    "modsecurity on;" + "modsecurity_rules_file /etc/nginx/modsecurity/modsecurity.conf"

# T2.6 WAF: peticion normal -> 200 (sin falsos positivos)
curl -sk -o /dev/null -w '%{http_code}\n' "https://$LB/products"                     # 200

# T2.7 WAF: inyeccion SQL -> 403 (bloqueada por OWASP CRS)
curl -sk -o /dev/null -w '%{http_code}\n' --get --data-urlencode "id=1' OR '1'='1" "https://$LB/products"
#    Esperado: 403 (regla CRS 942xxx, SQL Injection)

# T2.8 WAF: XSS -> 403
curl -sk -o /dev/null -w '%{http_code}\n' --get --data-urlencode "q=<script>alert(1)</script>" "https://$LB/products"
#    Esperado: 403 (regla CRS 941xxx, XSS)

# T2.9 Rate limiting: rafaga de 60 -> mezcla de 200 y 503
for i in $(seq 1 60); do curl -sk -o /dev/null -w '%{http_code}\n' "https://$LB/products"; done | sort | uniq -c
#    Esperado: ~30 200 + ~30 503 (rate 10 r/s + burst 20; el resto se rechaza)

# T2.10 Registro de auditoria del WAF con las trazas bloqueadas
ansible lb -m shell -a "tail -5 /var/log/nginx/modsec_audit.log | grep -E 'TXID|Inbound Anomaly|Message' | head -10"
```

> Si T2.7/T2.8 devuelven `200`, revisar: (a) que `modsec_rule_engine` sea `On`
> (no `DetectionOnly`), (b) que el módulo esté cargado (`nginx -T`), (c) que el
> CRS esté incluido (`modsecurity.conf` → `Include .../owasp-crs/rules/*.conf`).

---

## 3. Semana 3 — Health-checks ante caídas y bloqueo de vectores OWASP

### 3.1 Cómo funcionan los health-checks en Nginx open source

- Nginx OSS usa **health-checks pasivos**: cada `server` del `upstream` tiene
  `max_fails=3 fail_timeout=10s`. Tras 3 errores conectivos/de timeout en 10s,
  el nodo se **retira del pool** durante `fail_timeout`.
- Mientras un nodo está retirado, todo el tráfico va al superviviente (aquí,
  el otro app-node): **el servicio no se cae**.
- `proxy_next_upstream error timeout ...` hace que, incluso en los primeros
  intentos (antes de que el nodo se marque como caído), la petición se
  reintente contra el otro nodo del pool.
- Los health-checks **activos** (sondas periódicas) son exclusivos de
  Nginx Plus; en nuestro caso la detección ocurre al recibir peticiones,
  que es lo que exige el enunciado y es suficiente para este lab.

### 3.2 Test de balanceo y failover (caída de un nodo)

```bash
# Desde el control node
export LB=156.35.x.x

# A) Distribución normal: alternan los dos nodos
for i in $(seq 1 12); do curl -sk "https://$LB/products"; echo; done | grep '"host"' | sort | uniq -c
#    Esperado: ~6 de cada uno (cantabrico-app-node-01 / cantabrico-app-node-02)

# B) Caida de app-node-02 (mock de aplicacion; via bastion)
ssh sysadmin_cantabrico@<FIP_BASTION>
ssh sysadmin_cantabrico@10.10.99.22 "sudo systemctl stop mock-app.service"

# C) Balanceo con un nodo caido: TODAS las respuestas del superviviente
for i in $(seq 1 20); do curl -sk "https://$LB/products"; echo; done | grep '"host"' | sort | uniq -c
#    Esperado: 20 x cantabrico-app-node-01 y 0 x cantabrico-app-node-02
#    (ademas los codigos devueltos son 200: el usuario jamas ve el corte)

# D) Recuperacion: se vuelve a arrancar y el nodo reaparece
ssh sysadmin_cantabrico@10.10.99.22 "sudo systemctl start mock-app.service"
for i in $(seq 1 12); do curl -sk "https://$LB/products"; echo; done | grep '"host"' | sort | uniq -c
#    Esperado: vuelven a aparecer los dos nodos tras el fail_timeout
```

> Opcional: comprobar el `stub_status` del pool (solo accesible desde mgmt):
> ```bash
> ansible lb -m shell -a "curl -s http://127.0.0.1/nginx_status"
> #    Esperado: Active connections ...; server accepts/handled/requests ...
> ```

### 3.3 Test de bloqueo de vectores OWASP (OWASP CRS)

Ejemplos de payloads (todos deben acabar en `403`, y la petición benigna en `200`):

```bash
curl -sk -o /dev/null -w '%{http_code}\n' "https://$LB/products"                                  # 200

# SQL Injection (reglas CRS 942xxx)
curl -sk -o /dev/null -w '%{http_code}\n' --get --data-urlencode "id=1' OR '1'='1"  "https://$LB/products"
curl -sk -o /dev/null -w '%{http_code}\n' --get --data-urlencode "id=1; DROP TABLE products; --" "https://$LB/products"
curl -sk -o /dev/null -w '%{http_code}\n' --get --data-urlencode "id=UNION SELECT username,password FROM users" "https://$LB/products"

# XSS (reglas CRS 941xxx)
curl -sk -o /dev/null -w '%{http_code}\n' --get --data-urlencode "q=<script>alert(1)</script>"   "https://$LB/products"
curl -sk -o /dev/null -w '%{http_code}\n' --get --data-urlencode "q=<IMG SRC=javascript:alert('XSS')>" "https://$LB/products"

# Comando/inyeccion OS (reglas CRS 932xxx)
curl -sk -o /dev/null -w '%{http_code}\n' --get --data-urlencode "cmd=; cat /etc/passwd"          "https://$LB/products"
```

Esperado: las cinco peticiones maliciosas devuelven **403** y la benigna **200**
(ausencia de falsos positivos).

Evidencia en el log de auditoría (para la memoria del proyecto):

```bash
ansible lb -m shell -a "grep -E '\"id=1.OR|UNION|script|passwd' /var/log/nginx/modsec_audit.log | tail -5"
#    Esperado: mensajes "Inbound Anomaly Score Exceeded" + TXID + id de regla
```

### 3.4 (Opcional) Script de verificación automatizada `scripts/test_security.sh`

Si el equipo quiere automatizar la S3 (el `.gitignore` actual ignora `*.sh`;
añadir `!scripts/*.sh` para commitearlo):

```bash
#!/usr/bin/env bash
# test_security.sh — Integrante 2: verificacion del perimetro.
# Uso:  LB_FIP=156.35.x.x ./test_security.sh [--balancing|--waf|--rate|--tls|--failover|all]
set -uo pipefail
LB_FIP="${LB_FIP:-}"
[[ -n "$LB_FIP" ]] || { echo "Usa: LB_FIP=<ip> $0"; exit 1; }
B="https://$LB_FIP"; C="curl -sk --max-time 5"; PASS=0; FAIL=0
ok(){ echo "  [OK]   $1"; PASS=$((PASS+1)); }
bad(){ echo "  [FAIL] $1"; FAIL=$((FAIL+1)); }
note(){ echo "  [----] $1"; }

balancing() {
  echo "== Balanceo round-robin (12 peticiones) =="
  local hosts
  hosts=$(for i in $(seq 1 12); do $C "$B/products"; echo; done | grep -o '"host": "[^"]*"' | sort | uniq -c)
  echo "$hosts"
  echo "$hosts" | grep -q "cantabrico-app-node-01" && echo "$hosts" | grep -q "cantabrico-app-node-02" \
    && ok "los 2 nodos reciben trafico" || bad "falta algun nodo en la distribucion"
}

waf() {
  echo "== WAF OWASP CRS =="
  $C -o /dev/null -w '%{http_code}\n' "$B/products" | grep -q 200 && ok "benigna -> 200" || bad "benigna no es 200"
  $C -o /dev/null -w '%{http_code}\n' --get --data-urlencode "id=1' OR '1'='1" "$B/products" | grep -q 403 \
    && ok "SQLi bloqueado (403)" || bad "SQLi NO bloqueado"
  $C -o /dev/null -w '%{http_code}\n' --get --data-urlencode "q=<script>alert(1)</script>" "$B/products" | grep -q 403 \
    && ok "XSS bloqueado (403)" || bad "XSS NO bloqueado"
}

rate() {
  echo "== Rate limiting (60 peticiones) =="
  local codes
  codes=$(for i in $(seq 1 60); do $C -o /dev/null -w '%{http_code}\n' "$B/products"; done | sort | uniq -c)
  echo "$codes"
  echo "$codes" | grep -q "503" && ok "hay 503 (limite aplicado)" || bad "sin 503"
}

tls() {
  echo "== TLS endurecido =="
  echo | openssl s_client -connect "$LB_FIP:443" -tls1_2 </dev/null 2>/dev/null | grep -q "Cipher is" \
    && ok "TLSv1.2 OK" || bad "TLSv1.2 falla"
  echo | openssl s_client -connect "$LB_FIP:443" -tls1 </dev/null 2>/dev/null | grep -qi "alert\|error" \
    && ok "TLSv1.0 rechazado" || bad "TLSv1.0 NO rechazado"
  $C -sI "$B/" | grep -qi "strict-transport-security" && ok "HSTS presente" || bad "HSTS ausente"
}

failover() {
  echo "== Failover (para: parar mock en app-node-02 via bastion, luego re-ejecutar) =="
  note "1) ssh <BASTION> ; ssh 10.10.99.22 'sudo systemctl stop mock-app.service'"
  note "2) re-ejecuta: $0 --balancing  -> solo app-node-01"
  note "3) ssh 10.10.99.22 'sudo systemctl start mock-app.service'"
}

case "${1:-all}" in
  --balancing) balancing ;;
  --waf)       waf ;;
  --rate)      rate ;;
  --tls)       tls ;;
  --failover)  failover ;;
  *) balancing; waf; rate; tls ;;
esac
echo "== Resumen: $PASS OK / $FAIL FAIL =="
exit $FAIL
```

---

## 4. Checklist final «Mi parte está hecha»

- [ ] S1 · Rol `perimeter_lb` creado con estructura `defaults/handlers/tasks/templates`.
- [ ] S1 · `site.yml` incluye el play del grupo `[lb]` con el rol `perimeter_lb`.
- [ ] S1 · `nginx` activo (`enabled`) y `nginx -t` OK.
- [ ] S1 · `/products` alterna entre `cantabrico-app-node-01` y `-02` (round-robin).
- [ ] S2 · HTTP → HTTPS (301) y HTTPS sirviendo con certificado autofirmado + SANs.
- [ ] S2 · Solo `TLSv1.2`/`TLSv1.3`; ciphers seguros; HSTS y cabeceras de seguridad presentes.
- [ ] S2 · Módulo `ngx_http_modsecurity_module` cargado (`nginx -T` lo muestra).
- [ ] S2 · OWASP CRS activo: SQLi y XSS devuelven `403`; petición benigna `200`.
- [ ] S2 · Rate limiting: ráfaga de peticiones produce `503`.
- [ ] S3 · Failover probado: parado `app-node-02`, todo el tráfico lo sirve `app-node-01` sin cortes; al arrancar de nuevo, reaparece en el pool.
- [ ] S3 · Log de auditoría de ModSecurity con las trazas bloqueadas (evidencia para la memoria).
- [ ] Coordinado con Integrante 1: FIP del LB asociada al puerto DMZ (para probar desde Internet).

---

## 5. Mapa resumen: semana → ficheros → verificación

| Semana | Qué se construye | Ficheros | Comando | Verificación |
|---|---|---|---|---|
| S1 | Rol + Nginx LB | `roles/perimeter_lb/**`, `site.yml`, `all.yml` | `ansible-playbook site.yml --limit lb` | `systemctl is-active nginx`; round-robin en `/products` |
| S2 | WAF + TLS + rate limit | `tasks/main.yml`, `ecommerce.conf.j2`, `modsec-load.conf` | `ansible-playbook site.yml --limit lb` | 301→443, TLS1.2/1.3, 403 en SQLi/XSS, 503 en ráfaga |
| S3 | Health-checks + tests | (sin ficheros nuevos; `scripts/test_security.sh` opcional) | `scripts/test_security.sh` | Failover sin cortes; payloads OWASP bloqueados |

---

## 6. Coordinación con Integrante 1 — FIP del balanceador

`terraform/` hoy solo asocia FIP al bastión. Para probar el WAF desde Internet
conviene añadir la FIP del LB (mismo patrón que el bastión). Snippet opcional:

**`terraform/variables.tf`:**
```hcl
variable "lb_floating_ip" {
  description = "Direccion IP flotante preexistente en Horizon para el Balanceador (puerto DMZ). Opcional."
  type        = string
  default     = ""
}
```

**`terraform/instances.tf`** (al final, junto al bloque de la FIP del bastión):
```hcl
data "openstack_networking_floatingip_v2" "fip_lb" {
  count   = var.lb_floating_ip != "" ? 1 : 0
  address = var.lb_floating_ip
}

resource "openstack_networking_floatingip_associate_v2" "fip_lb_assoc" {
  count       = var.lb_floating_ip != "" ? 1 : 0
  floating_ip = data.openstack_networking_floatingip_v2.fip_lb[0].address
  port_id     = openstack_networking_port_v2.port_lb_dmz.id
}
```

Y en `terraform.tfvars` añadir `lb_floating_ip = "TU_IP_FLOTANTE_LB"` (reservando
la IP antes en Horizon, como se hizo con la del bastión). Después actualizar
`lb_fip` en `group_vars/all.yml` con esa IP y re-ejecutar el rol para regenerar
el certificado con el SAN correcto (o simplemente volver a correr el playbook,
que es idempotente).

> Si no se desea tocar Terraform, la FIP puede asociarse a mano:
> Horizon → Project → Network → Floating IPs → Associate → puerto
> `cantabrico-port-lb-dmz`.

---

## 7. Troubleshooting

| Síntoma | Causa probable | Solución |
|---|---|---|
| `nginx -t` falla con `module ... is not binary compatible` | módulo compilado contra otra versión/ABI de nginx | Borrar `/etc/nginx/modules/ngx_http_modsecurity_module.so` y re-ejecutar (el rol lo recompila con la versión exacta instalada) |
| `nginx -t` falla en `unknown directive "load_module"` | la directiva está fuera del contexto permitido | Está bien en `/etc/nginx/modules-enabled/*.conf` (se incluye al inicio); comprobar que el `.so` existe |
| `modsecurity on;` → `unknown directive` | el módulo no se ha cargado (`nginx -T` no lo lista) | Revisar `50-modsecurity.conf` y que el `.so` esté en `/etc/nginx/modules/` |
| SQLi/XSS devuelven 200 (no 403) | motor en `DetectionOnly` o CRS no incluido | `SecRuleEngine On` + comprobar `Include .../rules/*.conf`; reiniciar/recargar nginx |
| Depende: mismos tests dan 403 con `DetectionOnly` | el log de auditoría muestra la traza pero no bloquea | Decidir bloqueo real: `modsec_rule_engine: On` |
| Rate limiting afecta a tus propios tests | el límite es por IP de origen | Subir `rate_limit_burst` o hacer los tests desde distintas IPs; es el comportamiento deseado |
| La compilación tarda / baja la consola | primera ejecución con `make modules` | Normal; usar `-j{{ ansible_processor_vcpus }}` (ya incluido) y esperar |
| Falsos positivos del CRS | paranoia/umbral por defecto estrictos para el mock | Subir `tx.blocking_anomaly_score` o bajar `tx.paranoia_level` en `crs-setup.conf` |

---

## 8. Referencias

- Proyecto: [`docs/definición_inicial_proyecto.md`](definición_inicial_proyecto.md) (plan e Integrante 2, fases S1–S3).
- Flujo Terraform→Ansible y salto por bastión: [`docs/flujo-infra-supply.md`](flujo-infra-supply.md).
- Cifrado de secretos (vault): [`docs/pasos-cifrar-secretos-ansible.md`](pasos-cifrar-secretos-ansible.md).
- Test previo del mock (Integrante 3): [`docs/test-ansible-ok.md`](test-ansible-ok.md) (el mock ya expone `/health` y el host).
- ModSecurity-nginx connector: <https://github.com/owasp-modsecurity/ModSecurity-nginx>.
- OWASP Core Rule Set: <https://github.com/coreruleset/coreruleset>.
- Nginx upstream health checks (pasivos): <https://docs.nginx.com/nginx/admin-guide/load-balancer/http-health-check/>.