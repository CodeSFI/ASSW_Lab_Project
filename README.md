# Infraestructura E-commerce Segura sobre OpenStack

Despliegue de un laboratorio de 5 VMs en OpenStack con defensa en profundidad:

- **DMZ** (10.10.10.0/24): `lb-proxy-01` — Nginx + ModSecurity/OWASP CRS (WAF), única FIP web (`lb_floating_ip`).
- **App** (10.10.20.0/24): `app-node-01/02` — mock API, sin acceso público.
- **Data** (10.10.30.0/24, **sin gateway**): `db-core-01` — PostgreSQL aislado.
- **Mgmt** (10.10.99.0/24): `bastion-ops-01` — único punto de entrada SSH (FIP `bastion_floating_ip`).

Toda la administración pasa por el bastión (ProxyJump/ProxyCommand).


## Problemas conocidos del entorno

El clúster OpenStack del laboratorio es **extremadamente lento**, y es la causa principal de los problemas operativos, no un defecto del código:

- **Boot por VM ~15 min** (cloud-init). Hasta que no llega al `login:`/`ssh.service` **Started**, los saltos SSH a los nodos fallan con *"Connection closed by UNKNOWN port 65535"* o *"Timeout waiting for privilege escalation prompt"*.
- **API de Nova bajo carga**: respuestas con `408` y timeouts del proveedor Terraform (v3.4.0, 30 min por defecto). **Mitigación aplicada**: `timeouts { create/update = "2h" }` en las 5 instancias y `depends_on` de los routers en las asociaciones de FIP.
- **Ráfagas de autenticación al bastión**: varios saltos `-J`/ProxyCommand seguidos disparan rechazos `Permission denied (publickey)` (limitación del entorno). **Mitigación aplicada**: conexión maestra persistente (`ControlMaster`/`ControlPersist`) + `forks = 1` en Ansible, para autenticar contra el bastión una sola vez.
- Tras recrear VMs hay que limpiar `known_hosts` (las claves host cambian en cada rebuild).

## Base teórica

La arquitectura está bien fundamentada (zonas aisladas, data-net sin router, SGs de mínimos privilegios, acceso exclusivo por bastión, TLS+HSTS+WAF+rate limiting en el perímetro, secretos en Ansible Vault). **Debería funcionar conforme al diseño cuando el entorno responda**; los fallos observados son de temporización del clúster, no de configuración.

## Cómo verificarlo

```bash
# 1) Acceso al bastión
ssh -i ~/.ssh/Lab_project.pem ubuntu@<BASTION_FIP>

# 2) Probar todos los nodos a través del bastión (una sola auth por ControlMaster)
cd ansible && ansible all -m ping

# 3) Configurar las VMs (vault resuelto por ansible.cfg)
ansible-playbook -i inventory.ini site.yml

# 4) Verificación del perímetro (uso: LB_FIP=<IP> scripts/test_security.sh)
LB_FIP=156.35.98.152 ../scripts/test_security.sh
```
