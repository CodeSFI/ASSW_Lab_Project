# Pasos para cifrar los secretos de Ansible (reproducibilidad)

Guía reproducible para el equipo: qué instalar, cómo cifrar los secretos con
**Ansible Vault** y cómo ejecutar el playbook. El objetivo es que cualquier
compañero pueda clonar el repo y suministrar la infraestructura de la misma
forma, **sin exponer nunca contraseñas en claro**.

---

## 1. Qué hace falta instalar (control node)

Todos los pasos se ejecutan en el nodo de control de Ansible (normalmente la
máquina del administrador, no en las VMs). Requisitos:

| Herramienta | Versión mínima | Motivo |
|---|---|---|
| Python 3.8+ | ya incluida en la mayoría de distribuciones | Base de Ansible |
| Ansible (core) | 2.15+ / extra 2.10+ | Playbooks, roles y `ansible-vault` |
| Ansible Vault | incluido con Ansible | Cifrado de secretos |
| Colección `community.postgresql` | última estable | Módulos DB del rol `database` |

### Instalación (Debian/Ubuntu)

```bash
sudo apt update
sudo apt install -y python3 python3-pip
sudo pip install "ansible>=2.15"
ansible-galaxy collection install -r inventory/requirements.yml
```

> En Windows clásico (PowerShell) Ansible no se instala de forma nativa; usa
> WSL2 con una distro Ubuntu o un contenedor/VM Linux como control node.

### Instalación en este proyecto

Desde `ansible/`:

```bash
ansible-galaxy collection install -r requirements.yml
```

---

## 2. Configurar la clave de Vault (fuera del repo)

La frase de Vault **nunca se guarda en el repositorio**. Cada miembro la crea
en su propio home:

```bash
# La ubicación EXTERNA al repo está definida en ansible.cfg:
#   vault_password_file = ~/.ansible_vault_pass_cantabrico
printf '%s' 'TU_FRASE_MAESTRA_LARGA' > ~/.ansible_vault_pass_cantabrico
chmod 600 ~/.ansible_vault_pass_cantabrico
```

> La frase maestra debe compartirse fuera de banda (gestor de contraseñas del
> equipo, clave pública/privada, etc.) y ser distinta para cada entorno.
> `chmod 600` evita que otros usuarios del sistema la lean.

---

## 3. Cifrar los secretos

El fichero `ansible/group_vars/vault.yml` contiene los valores en claro. Se
cifra de una vez:

```bash
cd ansible
ansible-vault encrypt group_vars/vault.yml
```

Resultado esperado: el fichero deja de ser legible y empieza por
`$ANSIBLE_VAULT;1.1;AES256`.

### Operaciones habituales

```bash
# Ver el contenido cifrado (sin modificarlo)
ansible-vault view group_vars/vault.yml

# Editar de forma segura (cifra de nuevo al guardar)
ansible-vault edit group_vars/vault.yml

# Regenerar clave / cambiar de passphrase
ansible-vault rekey group_vars/vault.yml

# Volver a dejar en claro (SOLO temporal, para debug; volver a cifrar tras ello)
ansible-vault decrypt group_vars/vault.yml
```

> Nota: `ansible.cfg` ya fija `vault_password_file`, así que no hará falta
> pasar `--ask-vault-pass` a estos comandos mientras el fichero de clave
> exista en `~/`.

---

## 4. Reproducibilidad del proceso para el equipo

Para que cualquier compañero reproduzca el flujo completo:

1. **Instalar dependencias** (§1) — `ansible` + colecciones.
2. **Crear su fichero de clave local** (§2) — `~/.ansible_vault_pass_cantabrico`
   con la misma frase maestra acordada.
3. **Asegurarse de que `vault.yml` está cifrado en el repo**:

   ```bash
   head -c 15 ansible/group_vars/vault.yml   # debe mostrar: $ANSIBLE_VAULT;1.1
   ```
4. **Ejecutar el suministro**:

   ```bash
   cd ansible
   ansible-playbook -i inventory.ini site.yml
   ```

La clave de Vault es idéntica para todo el equipo (misma frase maestra) y
`ansible.cfg` la localiza automáticamente; por eso el comando no necesita
`--ask-vault-pass`. Así, cualquier miembro despliega el mismo estado.

---

## 5. Precauciones de seguridad

- **Nunca hacer commit de `group_vars/vault.yml` en claro** ni del fichero de
  passphrase. Comprobación rápida:

  ```bash
  git status            # antes de commit, revisar qué se va a subir
  grep -rl '\$ANSIBLE_VAULT' ansible/ || echo "OK: vault.yml sigue cifrado"
  ```

- Los secretos cifrados **pueden** viajar en el repo (es seguro); solo la clave
  maestra queda fuera.

- Opcional: añadir una regla al `.gitignore` temporal si se necesita una copia
  en claro en algún entorno de dev (no recomendado):

  ```
  # .gitignore
  ansible/group_vars/vault.yml.plain
  ```

- Si un miembro sospecha que la passphrase se filtró, rehacer clave:
  `ansible-vault rekey group_vars/vault.yml` y difundir la nueva passphrase
  fuera de banda.

---

## 6. Estado actual del proyecto

- `ansible/group_vars/vault.yml` contiene **secretos generados en claro**
  (todavía sin cifrar). Unica acción pendiente §3: `ansible-vault encrypt`.
- `ansible/requirements.yml` ya define la colección `community.postgresql`.