# Flujo de Infraestructura → Suministro (Terraform → Ansible)

Este documento explica cómo se enlaza la **creación de la infraestructura**
con Terraform con el **suministro de configuración** (`provisioning`) con Ansible,
en el contexto de este proyecto de e-commerce sobre OpenStack.

---

## 1. Visión general

| Herramienta | Fase | Objetivo |
|---|---|---|
| **Terraform** | Infraestructura | Crear el "hardware virtual": redes, SGs, router, puertos e instancias |
| **Ansible** | Suministro | Configurar el software dentro de las VMs ya creadas |

Ambas fases se conectan mediante el **fichero puente**: `ansible/inventory.ini`.
Terraform garantiza las IPs fijas de gestión; Ansible necesita saber cuáles son
y cómo llegar a cada nodo.

```
Terraform                            Ansible
   │  Crea VMs, redes, IPs fijas ──────►  inventory.ini (IPs MGMT)
   │                                        │
   │                                        ▼
   └── Infra lista              site.yml + roles aplican configuración
                                        (PostgreSQL, mock API, WAF, ...)
```

---

## 2. Qué crea Terraform (la infraestructura)

`terraform apply` materializa en OpenStack (redes `networks.tf`, instancias
`instances.tf`):

- Las VMs con la clave SSH `Lab_project` inyectada (`key_pair = var.keypair_name`).
- **IPs fijas deterministas** en la red de gestión `10.10.99.0/24` para cada nodo
  (las direcciones de administración donde conectará Ansible).
- La **única** puerta SSH pública: el bastión, con su IP flotante
  `156.35.98.87` asociada a su puerto de MGMT (`instances.tf`).

**Qué deja listo para Ansible:**
- Nodos alcanzables únicamente desde la red MGMT.
- Acceso administrativo inicial garantizado mediante la clave pública inyectada.
- IPs de gestión estables y repetibles entre aplicaciones.

---

## 3. El inventory como puente

Ansible no sabe nada de OpenStack. Terraform "transmite" las direcciones de los
nodos mediante `ansible/inventory.ini`. Cada `ansible_host` es la **IP fija de
gestión (MGMT)** que Terraform garantiza:

| Host           | Rol                    | IP MGMT |
|----------------|------------------------|---------|
| `lb-proxy-01`  | Balanceador / WAF (DMZ)| 10.10.99.10 |
| `bastion-ops-01` | Salto SSH público    | 10.10.99.20 |
| `app-node-01`  | Mock API backend       | 10.10.99.21 |
| `app-node-02`  | Mock API backend       | 10.10.99.22 |
| `db-core-01`   | PostgreSQL             | 10.10.99.50 |

> **¿Por qué MGMT y no las de app/data?** Las IPs de app (`10.10.20.x`) y data
> (`10.10.30.x`) son redes funcionales de tráfico de negocio/datos. La red de
> datos ni siquiera tiene gateway (`no_gateway = true`) e ignora conexiones
> externas. La red MGMT es el plano de control aislado y exclusivo para
> administración, y es desde donde `sg-internal` permite SSH.

---

## 4. Conexión SSH a través del bastión (ProxyJump)

Las máquinas internas **no tienen IP pública** y `sg-internal` solo admite SSH
(22) desde la red MGMT. El único punto de entrada es el bastión, y todo el
tráfico administrativo salta por él:

```
Tu PC ──SSH(22)──► bastión 156.35.98.87 ──SSH(22)──► app-node 10.10.99.21
```

Eso lo configura `ansible.cfg`:

```ini
[ssh_connection]
ssh_args = -o ProxyCommand="ssh -W %h:%p sysadmin_cantabrico@156.35.98.87" \
           -o StrictHostKeyChecking=no
pipelining = True
```

- `ssh -W %h:%p` abre un **túnel transparente**: Ansible "dialoga" por SSH con
  la máquina interna pero la conexión TCP la reenvía el bastión.
- El usuario es `sysadmin_cantabrico` en todos los nodos (`remote_user` y vars
  de grupo en el inventory).
- `pipelining = True` reduce rondas SSH en playbooks con muchos pasos.

---

## 5. Comandos del flujo completo

```bash
# 1) Levantar la infraestructura
cd terraform
cp terraform.tfvars.example terraform.tfvars   # primera vez, con credenciales reales
terraform init
terraform apply -auto-approve
terraform output                                # comprobar IPs flotantes LB/Bastión

# 2) Verificar el salto SSH (opcional pero recomendado)
ssh sysadmin_cantabrico@156.35.98.87

# 3) Suministrar la configuración
cd ../ansible
ansible-playbook -i inventory.ini site.yml --ask-vault-pass
```

---

## 6. Estado actual y siguientes pasos

Estado del repositorio (a fecha de este documento):

- [x] `terraform/` — infraestructura completa implementada.
- [x] `ansible/inventory.ini` — IPs MGMT correctas.
- [x] `ansible/ansible.cfg` — ProxyCommand con la FIP real del bastión.
- [x] `ansible/group_vars/all.yml` — variables no sensibles.
- [x] `ansible/site.yml` — playbook maestro (roles `database` y `app_node`).
- [x] `roles/app_node` — mock HTTP en `8080` con `/health` bajo systemd/usuario no privilegiado.
- [x] `roles/database` — PostgreSQL escuchando en data-net (`10.10.30.50`), `pg_hba.conf` restringido, backup GPG con timer systemd.
- [ ] `group_vars/vault.yml` — contiene secretos **en claro**; falta cifrar:
      `ansible-vault encrypt group_vars/vault.yml` (con `~/.ansible_vault_pass_cantabrico` fuera del repo).
- [ ] Instalar colección requerida en el control node:
      `ansible-galaxy collection install -r requirements.yml`