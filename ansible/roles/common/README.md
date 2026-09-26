# Rol `common`

Capa **base** del suministro. Se aplica a **todas** las VMs del proyecto
(`app`, `db`, `lb` y `bastion`) mediante el primer play de `ansible/site.yml`:

```yaml
- name: Actualizacion base de todas las VMs
  hosts: all
  become: true
  roles:
    - role: common
```

## Objetivo

Dejar todos los sistemas operativos al día **antes** de suministrar cualquier
capa posterior, y mantenerlos parcheados de forma permanente con
`unfinished-upgrades` → `unattended-upgrades`.

> El rol **no crea ni modifica usuarios**, permisos `sudo` ni claves SSH. Eso es
> responsabilidad del inventario y de `group_vars/`.

## Estructura

```
common/
├── defaults/
│   └── main.yml    # 4 variables de configuración
└── tasks/
    └── main.yml    # 5 tareas
```

## `defaults/main.yml`

| Variable | Valor por defecto | Descripción |
|---|---|---|
| `common_apt_cache_valid_time` | `3600` | Segundos durante los que se considera válido el índice de `apt` descargado. Evita lanzar `apt update` en cada ejecución del playbook. |
| `common_apt_upgrade` | `dist` | Tipo de actualización: `dist` (permite cambiar dependencias, p. ej. kernel), `safe` o `full`. |
| `common_reboot_if_required` | `true` | Reiniciar automáticamente si el sistema lo pide tras la actualización. |
| `common_reboot_timeout` | `600` | Segundos de espera máxima del reinicio antes de que la tarea falle. |

## `tasks/main.yml`

| # | Tarea | Módulo | Detalle |
|---|---|---|---|
| 1 | Actualizar índice y paquetes del sistema | `ansible.builtin.apt` | `update_cache: true`, `cache_valid_time: {{ common_apt_cache_valid_time }}`, `upgrade: {{ common_apt_upgrade }}` |
| 2 | Instalar `unattended-upgrades` | `ansible.builtin.apt` | `state: present` |
| 3 | Habilitar actualizaciones de seguridad automáticas | `ansible.builtin.copy` | Escribe `/etc/apt/apt.conf.d/20auto-upgrades` con `APT::Periodic::Update-Package-Lists "1"` y `APT::Periodic::Unattended-Upgrade "1"`. `root:root`, modo `0644`. |
| 4 | Comprobar si hace falta reiniciar | `ansible.builtin.stat` | Testea `/var/run/reboot-required`; registra el resultado en `common_reboot_required`. |
| 5 | Reiniciar si la actualización lo requiere | `ansible.builtin.reboot` | Se ejecuta solo si `common_reboot_if_required` es true **y** existe `/var/run/reboot-required` (kernel, libc…). Usa `reboot_timeout: {{ common_reboot_timeout }}`. |

### Fichero generado

`/etc/apt/apt.conf.d/20auto-upgrades`:

```text
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
```

## Comportamiento

- **Idempotente**: una segunda ejecución consecutiva devuelve `ok` en las cinco
  tareas y no reinicia la máquina.
- La tarea 3 usa `content:` embebido en vez de `template`, así que el fichero se
  regenera en cada ejecución pero solo se marca `changed` si el contenido difiere.
- La tarea 5 puede **cortar la sesión SSH** del nodo cuando la actualización
  kernel lo requiere. Esto es seguro con el ProxyJump a través del bastión
  (`group_vars/internal.yml`), y es el motivo de `common_reboot_timeout`.

## Ejecución

```bash
# Solo contra un grupo, para probar
ansible-playbook -i inventory.ini site.yml --ask-vault-pass --limit lb

# Únicamente este rol, sin playbook
ansible all -i inventory.ini -b -m apt -a "upgrade=dist update_cache=yes"
```

## Verificación

```bash
# ¿Pendiente de reinicio?
ssh <nodo> 'sudo test -f /var/run/reboot-required && echo "REINICIO PENDIENTE" || echo "sin reinicio"'

# ¿Actualizaciones automáticas activas?
ansible all -i inventory.ini -m shell -a "cat /etc/apt/apt.conf.d/20auto-upgrades"

# ¿Timer de actualizaciones automáticas activo? (en Ubuntu es un timer, no un service)
ansible all -i inventory.ini -m shell -a "systemctl is-enabled unattended-upgrades.service || systemctl list-timers | grep apt"

# Versión del kernel cargada vs. instalada
ansible all -i inventory.ini -m shell -a "uname -r && dpkg -l linux-image-* | grep ^ii | tail -1"
```
