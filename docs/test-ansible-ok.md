# Test personal — Integrante 3: Capa Interna, Base de Datos, Backups y Secretos

Guía de pruebas para poder decir con confianza: **«mi parte está hecha»**.

Resumen de lo que cubre (por semana):

- **S1** — Mock API en `srv-ecommerce-app01/02` (estado + identificador de host) e integración de `group_vars/vault.yml`.
- **S2** — PostgreSQL en `srv-db-core01` escuchando solo en `data-net` + backup GPG con timer systemd.
- **S3** — Orquestación con `site.yml`, pruebas de restauración y verificación del cifrado.

**Referencias de la parte:**

| Host | IP Mgmt | IP funcional | Rol |
|---|---|---|---|
| `app-node-01` | 10.10.99.21 | 10.10.20.11 / data 10.10.30.11 | Mock API :8080 |
| `app-node-02` | 10.10.99.22 | 10.10.20.12 / data 10.10.30.12 | Mock API :8080 |
| `db-core-01` | 10.10.99.50 | data-net 10.10.30.50 | PostgreSQL :5432 |
| `bastion-ops-01` | 10.10.99.20 | FIP **156.35.98.87** | Salto SSH |

---

## 0. Prerrequisitos (una sola vez)

### 0.1 Preparar el control node
```bash
# En tu máquina (usa WSL2/Ubuntu si estás en Windows)
sudo apt install -y python3 python3-pip
sudo pip install "ansible>=2.15"

cd ansible
ansible-galaxy collection install -r requirements.yml
```

### 0.2 Clave maestra de Vault (fuera del repo)
```bash
printf '%s' 'LA_FRASE_MAESTRA_DEL_EQUIPO' > ~/.ansible_vault_pass_cantabrico
chmod 600 ~/.ansible_vault_pass_cantabrico
```
Ver guía completa: `docs/pasos-cifrar-secretos-ansible.md`.

### 0.3 Cifrar el vault (imprescindible antes de commit)
```bash
cd ansible
ansible-vault encrypt group_vars/vault.yml
head -c 15 group_vars/vault.yml    # debe mostrar: $ANSIBLE_VAULT;1.1
```

### 0.4 Verificar conectividad (debe dar pong en los 3 nodos)
```bash
cd ansible
ansible all -m ping
ansible db -m ping
```

---

## Semana 1 — Mock API + Vault

### T1.1 Suministrar los nodos de aplicación
```bash
cd ansible
ansible-playbook -i inventory.ini site.yml --limit app
```

### T1.2 Servicio del mock activo en ambos nodos
```bash
ansible app -m shell -a "systemctl is-active mock-app.service && systemctl is-enabled mock-app.service"
```
Esperado: `active` y `enabled` en `app-node-01` y `app-node-02`.

### T1.3 El mock devuelve estado **e identificador de host** distinto por nodo
Entra a un app-node por el bastión y prueba en local:
```bash
ssh sysadmin_cantabrico@156.35.98.87
ssh sysadmin_cantabrico@10.10.99.21 "curl -s http://127.0.0.1:8080/health"
ssh sysadmin_cantabrico@10.10.99.22 "curl -s http://127.0.0.1:8080/health"
```
Esperado (¡hosts distintos!):
```json
{"status": "ok", "service": "mock-ecommerce", "host": "cantabrico-app-node-01"}
{"status": "ok", "service": "mock-ecommerce", "host": "cantabrico-app-node-02"}
```

### T1.4 Endpoints de negocio
```bash
ssh sysadmin_cantabrico@10.10.99.21 "curl -s http://127.0.0.1:8080/products; echo; curl -s http://127.0.0.1:8080/products/1; curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:8080/products/999"
```
Esperado: lista JSON (con `host`), producto 1, y `404` para el id inexistente.

### T1.5 Vault cifrado y funcional
```bash
grep -c AES256 ansible/group_vars/vault.yml   # > 0
git status                                     # vault.yml modificado pero NO en claro
ansible app -m debug -a "var=hostvars[inventory_hostname]" | head -5   # no revienta con el vault
```

---

## Semana 2 — PostgreSQL + Backup GPG

### T2.1 Suministrar la base de datos
```bash
cd ansible
ansible-playbook -i inventory.ini site.yml --limit db
```

### T2.2 Servicio PostgreSQL activo
```bash
ansible db -m shell -a "systemctl is-active postgresql"
```

### T2.3 Escucha SOLO en data-net (NUNCA en mgmt ni externo)
```bash
ansible db -m shell -a "ss -ltnp | grep 5432"
```
Esperado: `10.10.30.50:5432` como dirección de escucha.

### T2.4 La app se autentica contra la DB por data-net
> **⚠︎ BLOQUEANTE conocido**: la regla `db_from_app` (`terraform/security_groups.tf:113`)
> solo permite 5432 desde `10.10.20.0/24` (app_subnet), pero el tráfico Apps→DB va
> por data-net (`10.10.30.0/24`). **Hasta que no se corrija ese SG, T2.4 fallará.**
> Fix propuesto en `security_groups.tf`:
> `remote_ip_prefix = openstack_networking_subnet_v2.data_subnet.cidr`
> (el `pg_hba.conf` del rol ya usa el rango de datos).

Desde un app-node (instala el cliente psql solo para la prueba):
```bash
ssh sysadmin_cantabrico@156.35.98.87
ssh sysadmin_cantabrico@10.10.99.21 "sudo apt-get install -y postgresql-client"
ssh sysadmin_cantabrico@10.10.99.21 "PGPASSWORD='<vault_ecommerce_db_password>' psql -h 10.10.30.50 -U db_ecommerce -d ecommerce -c 'SELECT 1;'"
```
Esperado: `1`.

### T2.5 Aislamiento de la DB (defensa en profundidad)
```bash
# Desde el bastión (mgmt): el puerto 5432 debe estar CERRADO/bloqueado
ssh sysadmin_cantabrico@156.35.98.87 "timeout 2 bash -c 'echo > /dev/tcp/10.10.99.50/5432' && echo OPEN || echo BLOQUEADO"
# Y también hacia la IP de data-net (red sin gateway)
ssh sysadmin_cantabrico@156.35.98.87 "timeout 2 bash -c 'echo > /dev/tcp/10.10.30.50/5432' && echo OPEN || echo BLOQUEADO"
```
Esperado: `BLOQUEADO` (o timeout) en ambos.

### T2.6 Backup manual on-demand
```bash
ansible db -m shell -a "ls -la /var/backups/postgresql/"   # antes: vacío o solo backups antiguos
ansible db -m shell -a "systemctl start ecommerce-backup.service"
ansible db -m shell -a "ls -la /var/backups/postgresql/"
```
Esperado: aparece `ecommerce-<fecha>.sql.gz.gpg`.

### T2.7 Verificar que el backup está REALMENTE cifrado (GPG)
```bash
ansible db -m shell -a "file /var/backups/postgresql/ecommerce-*.sql.gz.gpg"
```
Esperado: `PGP symmetrically encrypted data (AES256 cipher)` — no debe ser texto plano.

### T2.8 Verificar el timer automático (diario 02:30)
```bash
ansible db -m shell -a "systemctl list-timers ecommerce-backup.timer"
```
Esperado: `ecommerce-backup.timer` activo y `enabled`.

---

## Semana 3 — Orquestación `site.yml` + Restauración

### T3.1 Sintaxis del playbook
```bash
cd ansible
ansible-playbook -i inventory.ini site.yml --syntax-check
```

### T3.2 Despliegue completo (los DOS grupos)
```bash
ansible-playbook -i inventory.ini site.yml
```
Esperado: `PLAY RECAP` con `ok=…` en db + app, y **0 failed/unreachable**.

### T3.3 Idempotencia (segunda ejecución sin cambios)
```bash
ansible-playbook -i inventory.ini site.yml
```
Esperado: `changed=0` en todo (los handlers no se disparan dos veces).

### T3.4 Prueba de RESTAURACIÓN del backup
En `db-core-01` (vía bastión):
```bash
ssh sysadmin_cantabrico@156.35.98.87
ssh sysadmin_cantabrico@10.10.99.50

# Desencriptar + descomprimir
FICHERO=$(ls -1 /var/backups/postgresql/ecommerce-*.sql.gz.gpg | tail -1)
gpg --batch --yes --pinentry-mode loopback --passphrase '<vault_gpg_backup_passphrase>' -d "$FICHERO" | gunzip > /tmp/restore.sql
head -20 /tmp/restore.sql                        # debe ser SQL en claro (era el cifrado lo que protege)

# Restaurar en una BD de prueba y comprobar datos
sudo -u postgres createdb ecommerce_restore_test
sudo -u postgres psql ecommerce_restore_test < /tmp/restore.sql
sudo -u postgres psql ecommerce_restore_test -c "\d"                 # tablas presentes
sudo -u postgres dropdb ecommerce_restore_test
rm /tmp/restore.sql
```
Esperado: el dump se restaura sin errores y aparecen las tablas/objetos de la BD.

---

## Resultado final — checklist «Mi parte está hecha»

- [ ] T1.1–T1.4: mock activo en `app01`+`app02`, `/health` y `/products` responden e identifican el host (hostname distinto por nodo).
- [ ] T1.5 + 0.3: `group_vars/vault.yml` cifrado con Vault, sin secretos en claro en git.
- [ ] T2.2–T2.3: PostgreSQL activo escuchando **solo** en `10.10.30.50`.
- [ ] T2.4: la app conecta por data-net con `db_ecommerce` (PENDIENTE del fix de SG).
- [ ] T2.5: DB inaccesible desde mgmt/exterior.
- [ ] T2.6–T2.8: backup con cifrado GPG AES-256 funciona a demanda y con timer diario.
- [ ] T3.1–T3.2: `site.yml` orquesta db + app, 0 fallos.
- [ ] T3.3: idempotente (`changed=0`).
- [ ] T3.4: restauración probada sobre BD temporal.

> ⚠︎ Bloqueante pendiente antes de poder marcar T2.4: corregir la regla
> `db_from_app` del SG para permitir 5432 desde data-net, alineándose con el
> `pg_hba.conf` del rol. Avisar/coordinar con quien gestione `terraform/security_groups.tf`.