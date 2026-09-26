# Soluciones de errores de Ansible (guía práctica)

Resumen de los problemas encontrados durante el suministro del lab de e-commerce
(OpenStack) y sus soluciones, con los **comandos exactos** que funcionan. Está
pensado para quien use **WSL** o se encuentre con los mismos fallos: se recoge el
error, la causa real y el comando que lo desbloquea.

> Contexto del entorno: el repo se trabaja desde Windows con WSL2
> (`/mnt/c/Users/cimad/Code/ASSW_Lab_Project`), venv propio
> (`ansible/wsl-ansible-env`) y salto SSH por el bastión.

---

## 0. Resumen rápido (TL;DR)

| Síntoma | Causa | Solución |
|---|---|---|
| `AnsibleUndefinedVariable: 'vault_ecommerce_db_password' is undefined` | `group_vars/vault.yml` **nunca se auto-carga** (su nombre no coincide con ningún grupo del inventario) | `site.yml` lo carga explícitamente con `vars_files:` en cada play |
| Ansible **ignora `ansible.cfg`** (no aplica `vault_password_file`) | Repo en `/mnt/c`: directorio con permisos `777` (world-writable) | Prefijar siempre `ANSIBLE_CONFIG=$PWD/ansible.cfg` al ejecutar |
| El playbook **no descifra el vault** aunque el cfg se aplica | Fichero `~/.ansible_vault_pass_cantabrico` con contenido erróneo | Reescribirlo con la frase EXACTA (sin comillas/espacios) y `chmod 600` |
| `podman build` falla: `sd-bus call ... Access denied ... interactive authentication` | El usuario rootless no tiene sesión de usuario de systemd (crun gestiona los cgroups por `sd-bus`) | `loginctl enable-linger <usuario>` + `XDG_RUNTIME_DIR=/run/user/<uid>` en las tareas Podman |
| Tras el fix anterior, `podman build/run` se **queda colgado** (sin error) | (1) netavark helper `firewalld-reload` se bloquea con firewalld **inactivo**; (2) el disco OpenStack `vda1` se atasca por tramos (`jbd2_log_wait_commit`) y puede dejar el storage de podman en mal estado | `firewall_driver = "none"` (SG filtran); si sigue colgado, reset del storage (`app_node_reset_podman_storage: true`) o reiniciar la MV |

---

## 1. Error `'vault_ecommerce_db_password' is undefined`

### 1.1 Síntoma

El playbook falla en la tarea que renderiza el entorno de la app (o cualquier
tarea que use secretos), con una cadena como:

```
AnsibleUndefinedVariable: {{ ecommerce_db_password }}: {{ vault_ecommerce_db_password }}: 'vault_ecommerce_db_password' is undefined
```

Ocurre porque `group_vars/all.yml` define:

```yaml
ecommerce_db_password: "{{ vault_ecommerce_db_password }}"
gpg_backup_passphrase: "{{ vault_gpg_backup_passphrase }}"
```

y `vault_ecommerce_db_password` proviene de `group_vars/vault.yml` (cifrado)…
que **no se estaba cargando**.

### 1.2 Causa principal: `group_vars/vault.yml` no se auto-carga

El plugin `host_group_vars` de Ansible solo auto-carga de `ansible/group_vars/`
los ficheros **cuyo nombre coincide con un grupo del inventario**:

| Fichero | ¿Carga? | Motivo |
|---|---|---|
| `group_vars/all.yml` | ✅ | existe el grupo `all` (implícito) |
| `group_vars/internal.yml` | ✅ | existe el grupo `internal` (`[internal:children]`) |
| `group_vars/vault.yml` | ❌ | **no existe ningún grupo llamado `vault`** |

El fichero se ignora **silenciosamente**: no da error, simplemente sus variables
no entran en el contexto del play. Por eso `ansible-vault view` sí descifra,
`ansible-inventory --host` no muestra ninguna clave `vault_*`, y el error solo
aparece al resolver la variable en una plantilla.

Pruebas que lo confirmaron (diagnóstico en §4):

- `ansible-vault view group_vars/vault.yml` → descifra bien (la passphrase es correcta).
- `-e @group_vars/vault.yml` → las 3 claves `vault_*` SÍ cargan.
- Auto-load → `vault_vars=[]` (lista vacía).

### 1.3 Solución aplicada

`ansible/site.yml` carga el vault de forma explícita en **cada play** de la capa
que lo necesita (`db`, `app`, `lb`):

```yaml
- name: Suministro de la capa de aplicacion (mock API)
  hosts: app
  vars_files:
    - group_vars/vault.yml      # ← clave del fix
  become: true
  roles:
    - role: app_node
```

La ruta es relativa al playbook (`site.yml` está en `ansible/`), así que
`group_vars/vault.yml` resuelve. El descifrado se hace con la passphrase local
(§3); NO hace falta `--ask-vault-pass` si cfg + fichero de clave están bien.

> Con esto, `site.yml` ya NO depende del auto-load de `group_vars/vault.yml`.

### 1.4 ¿Por qué no se migró a la ubicación "canónica" `group_vars/all/vault.yml`?

Existe la alternativa oficial `group_vars/all/vault.yml` (directorio), y funciona,
**pero con dos pegas**:

1. Si coexisten `group_vars/all.yml` y el directorio `group_vars/all/`, el
   directorio **gana y sombrea el fichero**: se pierden `bastion_fip`, etc.
   (verificado empíricamente: el play empezó a fallar con
   `'bastion_fip' is undefined`). Habría que mover también el contenido de
   `all.yml` a `group_vars/all/main.yml`.
2. Eso barre ~33 referencias de rutas en la doc del equipo (incluida la de otro
   integrante).

Se descartó por invasivo; la solución `vars_files` es mínima y deja intacta la
estructura documentada.

---

## 2. Ansible ignora `ansible.cfg` desde `/mnt/c` (WSL)

### 2.1 Síntoma

Ejecutando el playbook desde el repo en `/mnt/c/...` (sin prefijo), Ansible no
aplica lo que hay en `ansible.cfg`: no funciona `vault_password_file`, `remote_user`,
`roles_path`, etc. El playbook se queja del vault aunque el cfg tenga la clave.

### 2.2 Causa

Cuando la ubicación del playbook/cfg es un directorio **world-writable**
(permisos `777`, típico de los mounts de Windows en WSL `/mnt/c`), Ansible
considera que el fichero de configuración local no es de confianza y **lo ignora**
(por seguridad). Se comprueba con:

```bash
stat -c '%A %a %n' /mnt/c/Users/cimad/Code/ASSW_Lab_Project   # drwxrwxrwx (777)
```

### 2.3 Solución: comando canónico de ejecución

Siempre que se trabaje desde `/mnt/c`, prefijar el cfg:

```bash
cd /mnt/c/Users/cimad/Code/ASSW_Lab_Project/ansible
ANSIBLE_CONFIG=$PWD/ansible.cfg ansible-playbook -i inventory.ini site.yml --limit app
```

Variantes equivalentes si no se quiere usar el cfg:

```bash
# Pedir la frase por teclado
ANSIBLE_CONFIG=$PWD/ansible.cfg ansible-playbook -i inventory.ini site.yml --ask-vault-pass

# Apuntar directamente al fichero de clave
ansible-playbook -i inventory.ini site.yml --vault-password-file ~/.ansible_vault_pass_cantabrico
```

> A medio plazo, la solución limpia es mover el repo al filesystem de WSL
> (p. ej. `~/lab/ASSW_Lab_Project`) y ejecutar sin prefijo, ya que ahí el
> directorio no es world-writable.

### 2.4 Cómo comprobar qué cfg se está usando

```bash
ANSIBLE_CONFIG=$PWD/ansible.cfg ansible-playbook --version
#   config file = /mnt/c/.../ansible/ansible.cfg          ← correcto cuando el prefijo actúa

ANSIBLE_CONFIG=$PWD/ansible.cfg ansible-config dump | grep -i vault
#   DEFAULT_VAULT_PASSWORD_FILE(...) = /home/<usuario>/.ansible_vault_pass_cantabrico
```

---

## 3. El fichero de passphrase del vault

### 3.1 Causa típica

`ansible.cfg` fija `vault_password_file = ~/.ansible_vault_pass_cantabrico`, pero si
el fichero no existe o su contenido no es la frase exacta, el descifrado falla
(o las variables del vault nunca llegan). Un caso real: el fichero tenía un
contenido erróneo (distinto de la frase maestra acordada).

### 3.2 Solución

```bash
# La frase se comparte fuera de banda (NO se commitea al repo).
printf '%s' 'LA_FRASE_MAESTRA_ACORDADA' > ~/.ansible_vault_pass_cantabrico
chmod 600 ~/.ansible_vault_pass_cantabrico
```

Reglas:

- El fichero debe contener **solo** la frase: sin comillas, sin espacios y sin
  salto de línea final (`printf '%s'` hace exactamente eso).
- Vive en el home de WSL (`/home/<usuario>/`), **no** en `/mnt/c`.
- `chmod 600` obligatorio (evita que otros usuarios lo lean).
- Comprobación:

  ```bash
  cd ansible
  ANSIBLE_CONFIG=$PWD/ansible.cfg ansible-vault view group_vars/vault.yml
  ```

  Si descifra sin pedir contraseña → cfg + passphrase correctos.

> ⚠️ La frase maestra NO debe escribirse en el repo (algunos ficheros del repo
> están cifrados y su passphrase fuera de banda). Ver
> `docs/pasos-cifrar-secretos-ansible.md`.

---

## 4. Diagnóstico paso a paso (para no repetir la búsqueda)

Orden lógico que permitió localizar el fallo anterior:

1. **Confirmar qué cfg usa Ansible**

   ```bash
   ansible-playbook --version        # ¿aparece "config file = .../ansible.cfg"?
   ```

   Si no aparece → problema de `ANSIBLE_CONFIG` (§2).

2. **Confirmar la passphrase**

   ```bash
   ansible-vault view group_vars/vault.yml
   ```

   Si descifra → passphrase bien. (Esto DESCARTA la clave como causa: el error
   seguía viniendo de otra parte.)

3. **Comprobar si el inventario ve las claves del vault**

   ```bash
   ANSIBLE_CONFIG=$PWD/ansible.cfg ansible-inventory -i inventory.ini --host app-node-01 --yaml
   ```

   Aparecen `ecommerce_db_*` (de `all.yml`) pero **ninguna `vault_*`** → el
   fichero `vault.yml` no se está cargando.

4. **Probe de nombres de variable en un play** (no imprime valores, solo nombres):

   ```yaml
   ---
   - hosts: app
     gather_facts: false
     tasks:
       - debug:
           msg: "{{ vars.keys() | select('match', '^vault_') | list | sort }}"
   ```

   - `vault_vars=[]` → `group_vars/vault.yml` no se auto-carga (§1.2).
   - `vault_vars=[...]` → todo correcto, buscar el fallo en otro lado.

5. **Confirmar que el secreto SÍ descifra en runtime**

   ```bash
   ansible-playbook -i inventory.ini probe.yml -e @group_vars/vault.yml
   ```

   Si con `-e @fichero` las claves aparecen, el secreto funciona y el problema es
   únicamente el auto-load de `group_vars/`.

---

## 5. Error `sd-bus ... Access denied ... interactive authentication` en `podman build` rootless

### 5.1 Síntoma

El playbook ya pasa la fase del vault y llega a **"Construir la imagen del
mock"**, que falla al ejecutar el `RUN pip install ...` del Containerfile:

```
error running container: from /usr/bin/crun creating container [...]:
sd-bus call: Access denied as the requested operation requires interactive
authentication. However, interactive authentication has not been enabled by
the calling program.: Permission denied
```

Precedido de los avisos de Podman:

```
level=warning msg="The cgroupv2 manager is set to systemd but there is no systemd user session available"
level=warning msg="Falling back to --cgroup-manager=cgroupfs"
```

### 5.2 Causa

El usuario rootless (`mockapp`, creado con `shell: /usr/sbin/nologin` y que
nunca inicia sesión) **no tiene sesión de usuario de systemd**:

- No existe `/run/user/<uid>` con su bus D-Bus.
- Tampoco existe la delegación de cgroups v2 del usuario
  (`user.slice/user-<uid>.slice`).

Al crear el contenedor del build, **crun necesita gestionar los cgroups** y lo
intenta por `sd-bus`; systemd/polkit responde "Access denied ... interactive
authentication" porque no hay una sesión con la que autenticar. Podman avisa
del *fallback* a `cgroupfs`, pero sin delegación real ese fallback no basta.
`podman run` sufre el mismo fallo; los comandos que no crean contenedores
(`podman image exists`, `podman image inspect`) funcionan.

### 5.3 Solución aplicada (rol `app_node`)

1. **Habilitar *linger*** para el usuario rootless (sesión de usuario
   persistente) y asegurar `user@<uid>.service` activa:

   ```yaml
   - name: Habilitar lingering para el usuario rootless (sesion de usuario de systemd)
     ansible.builtin.command: loginctl enable-linger {{ mock_user }}
     args:
       creates: /var/lib/systemd/linger/{{ mock_user }}

   - name: Asegurar la sesion de usuario de systemd activa (user@{{ mock_user_uid }}.service)
     ansible.builtin.systemd:
       name: "user@{{ mock_user_uid }}.service"
       state: started
   ```

2. **Apuntar `XDG_RUNTIME_DIR` al directorio real de sesión** en las tareas que
   usan Podman rootless durante el suministro (`image exists`, `inspect`,
   `build`):

   ```yaml
   environment:
     HOME: "{{ mock_home }}"
     XDG_RUNTIME_DIR: "/run/user/{{ mock_user_uid }}"
   ```

   El UID se obtiene con `id -u {{ mock_user }}` y se guarda con
   `set_fact: mock_user_uid`.

> Con *linger*, systemd arranca `user@<uid>.service` al boot, crea
> `/run/user/<uid>` con su bus y la delegación de cgroups; a partir de ahí
> crun crea los contenedores rootless sin errores.

### 5.4 Nota sobre el diseño del runtime

El contenedor en **runtime** (`mock-app.service`, unidad **system** con
`User=mockapp` y `--cgroups=disabled`) **no depende** de la sesión de usuario;
el *linger* se añadió únicamente porque el **build** de imágenes no puede
desactivar los cgroups por contenedor. Si algún día se quisiera evitar el
*linger*, el build debería ejecutarse con una sesión activa o la imagen
construirse y distribuirse como artefacto.

### 5.5 Fase 2: con el *linger* activo, `podman build/run` se queda **colgado**

#### 5.5.1 Síntoma

Tras aplicar el fix del *linger*, el playbook ya no falla con el error `sd-bus`,
pero la tarea **"Construir la imagen del mock"** se queda **colgada** sin
terminar (y tampoco responde a `timeout`). Un `podman run` de prueba reproduce
el cuelgue incluso con `--network=none` (no es un problema de red).

#### 5.5.2 Hallazgos (evidencia recogida en `app-node-01`)

1. **Podman real en los nodos: `5.7.0`** (vía `apt`), no `3.4.4` como se
   asumía. Usa el backend de red **netavark**.
2. **`firewalld` instalado pero INACTIVO.** El helper `netavark
   firewalld-reload` quedó **colgado más de 1h30** (proceso sin estado D,
   esperando la activación de firewalld por D-Bus).
3. El hilo principal de podman colgado estaba en
   `stat=D` / `wchan=jbd2_log_wait_commit` → espera el **commit del journal de
   ext4** (un `fsync` que no completa), en una operación de su almacenamiento.
4. **El disco no estaba globalmente atascado**: un `dd` de 128 MiB + `fsync`
   tardó 0,17 s (980 MB/s) justo cuando podman se colgaba → el storage rootless
   (o el journal en ese punto) quedó en un estado que cuelga a podman.
5. El `dmesg` del nodo muestra que el disco **ya se atascaba antes** de nuestro
   trabajo: `INFO: task fwupd:1627 blocked for more than 122 seconds` con la
   misma pila `jbd2_log_wait_commit`. La unidad OpenStack `vda1` (ext4,
   `errors=remount-ro,commit=30,discard`) se bloquea **por tramos**.

#### 5.5.3 Soluciones aplicadas (rol `app_node`)

1. **`firewall_driver = "none"`** en `/etc/containers/containers.conf.d/`
   (`containers-network.conf`): netavark deja de hablar con firewalld. El
   filtrado de red lo hacen los Security Groups de OpenStack, así que el host no
   necesita programar reglas de firewall.
2. **Limpieza idempotente de procesos podman** al inicio del rol (mata
   `podman`/`conmon`/`slirp4netns`/`pasta` del usuario y los helpers
   `netavark firewalld-reload`): un run/build cortado no vuelve a bloquear el
   siguiente (el flock del storage se libera al morir el proceso).
3. **Reset opt-in del storage** (`app_node_reset_podman_storage: true`, por
   defecto `false`): borra
   `/opt/mock-ecommerce/.local/share/containers/storage` para que podman
   recree el storage y reconstruya la imagen desde cero (recuperación del
   estado "cuña" tras un build cortado durante un bloqueo de disco).

#### 5.5.4 Estado de la investigación y acciones pendientes

El cuelgue **no quedó 100% root-causado** (las MV se apagaron antes de
confirmarlo). Las dos hipótesis consistentes con la evidencia:

- **A — Storage "cuña"**: el storage rootless quedó en un estado que no
  completa sus `fsync` (el disco estaba sano en las pruebas). Solución: reset →
  §5.5.3.3.
- **B — Disco OpenStack inestable** (`vda1` se atasca por tramos, evidencia
  `fwupd` en el propio `dmesg`): una escritura de podman espera a un journal que
  tarda minutos. Solución: esperar/reintentar o reiniciar la MV; si persiste, es
  infraestructura (revisar/recrear el volumen).

**Próximos pasos cuando las MV estén operativas:**

1. `--syntax-check` y ejecución del playbook (`site.yml --limit app`) → si el
   build cuelga, ejecutar con `-e app_node_reset_podman_storage=true` y repetir.
2. Si el cuelgue persiste tras el reset y el nodo sigue congelado en escrituras,
   reiniciar la MV y volver a intentar: si vuelve a atascarse, el problema es el
   volumen (tratar desde Horizon/OpenStack).
3. Recordatorio: el fix del SG `db_from_app` → data-subnet sigue **sin aplicar**
   en la infra viva (ver §7).

---

## 6. Trampas y comportamientos aprendidos

### 6.1 `group_vars/all/` sombrea a `group_vars/all.yml`

Si existen a la vez el fichero `group_vars/all.yml` y el directorio
`group_vars/all/`, Ansible da prioridad al directorio y **descarta el fichero**.
Verificado: al añadir `group_vars/all/vault.yml` sin tocar `all.yml`, el play
empezó a fallar con `'bastion_fip' is undefined` (todas las variables de
`all.yml` desaparecieron). Si algún día se migra al formato de directorio, hay
que mover **todo** el contenido de `all.yml` a `group_vars/all/main.yml`.

### 6.2 `--check` en el play de `app` "falla" al final (y está bien)

```bash
ANSIBLE_CONFIG=$PWD/ansible.cfg ansible-playbook -i inventory.ini site.yml --limit app --check
```

En modo simulación se recorren todas las tareas y la última puede fallar con:

```
Could not find the requested service mock-app.service
```

**Es esperado**: en check mode la unidad no llega a instalarse, así que el módulo
`systemd` no la encuentra. No es un error real. Lo útil del check mode es que las
tareas `template`/`copy` **sí renderizan**, así que sirve para confirmar que una
plantilla (como el env del contenedor) ya se resuelve sin errores de variables.

### 6.3 `ansible-vault` descifra pero el play no carga el fichero

`ansible-vault view`/`edit` usan un camino de descifrado directo, y
`-e @fichero`/`vars_files` también. El auto-load de `group_vars/` es el único
puerto que exige coincidencia de nombre con un grupo. Síntoma clásico:
"el vault descifra a mano pero el playbook dice undefined".

---

## 7. Verificación del despliegue del mock (PostgreSQL real)

Una vez el playbook termina sin errores (imagen construida, unidad arrancada):

```bash
# Sobre cada app-node (o vía bastión + ProxyJump):
systemctl is-active mock-app.service      # active
curl -s http://127.0.0.1:8080/health       # incluye "host": "<nombre-del-nodo>"
curl -s http://127.0.0.1:8080/dbcheck      # 200 -> {"db": "ok", ...}
curl -s http://127.0.0.1:8080/products     # catálogo leído de PostgreSQL (no 503)
journalctl -u mock-app.service -n 50       # log de la unidad
```

> Si `/dbcheck` o `/products` devuelven `503 db_unavailable`, el contenedor
> arrancó pero **no llega a PostgreSQL** `10.10.30.50:5432`. Comprobar el
> security group: la regla `db_from_app` debe apuntar a la subred de datos
> (`10.10.30.0/24`, no `10.10.20.0/24`). Ver `terraform/security_groups.tf` y
> hacer `terraform plan && terraform apply` si la infra viva aún no está corregida.

---

## 8. Notas de seguridad y convenciones del repo

- `ansible/group_vars/vault.yml` está en `.gitignore` (`group_vars/.gitignore`
  contiene `vault.yml`): **nunca se commitea**.
- Los secretos cifrados SÍ pueden viajar en el repo; la **frase maestra no**
  (fuera de banda, en `~/.ansible_vault_pass_cantabrico` de cada miembro).
- Si se sospecha una fuga de la frase: `ansible-vault rekey group_vars/vault.yml`
  y difundir la nueva fuera de banda.
- Los comandos de este documento asumen ejecución desde `ansible/` y con el venv
  activo (`wsl-ansible-env`) o el binario del venv en `PATH`.

---

## 9. Referencias cruzadas

- `docs/pasos-cifrar-secretos-ansible.md` — instalación del control node y cifrado del vault.
- `docs/flujo-infra-supply.md` — flujo Terraform → Ansible y salto por bastión.
- `docs/test-ansible-ok.md` — contrato de pruebas del suministro (incluye `T2.4` de vault y las comprobaciones de `/dbcheck` y `/products`).
- `docs/definición_inicial_proyecto.md` — arquitectura general del despliegue.