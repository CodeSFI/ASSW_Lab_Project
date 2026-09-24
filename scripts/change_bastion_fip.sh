#!/usr/bin/env bash
#
# change_bastion_fip.sh
#
# Sustituye la IP flotante (FIP) pública del bastión en los dos ficheros
# donde está anclada:
#
#   ansible/group_vars/all.yml  -->  línea  bastion_fip: <IP>
#   ansible/inventory.ini       -->  línea  bastion-ops-01 ansible_host=<IP>
#
# Uso:
#   scripts/change_bastion_fip.sh
#
# El script muestra las líneas actuales con la IP que se va a sustituir y
# pide la nueva. Responder "N" (o "no") cancela sin tocar nada.

set -euo pipefail

# ── Rutas (relativas a la raíz del repo) ──────────────────────────────────────
BASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ALL_YML="$BASE_DIR/ansible/group_vars/all.yml"
INVENTORY="$BASE_DIR/ansible/inventory.ini"

# ── Comprobaciones previas ────────────────────────────────────────────────────
for f in "$ALL_YML" "$INVENTORY"; do
    if [[ ! -f "$f" ]]; then
        echo "ERROR: no se encuentra el fichero: $f" >&2
        exit 1
    fi
done

# ── IP actual en cada fichero ─────────────────────────────────────────────────
BIP_ALL="$(sed -nE "s/^bastion_fip:[[:space:]]*([0-9]+\.[0-9]+\.[0-9]+\.[0-9]+).*/\1/p" "$ALL_YML" | head -n1)"
BIP_INV="$(sed -nE "s/^bastion-ops-01[[:space:]]+ansible_host=([0-9]+\.[0-9]+\.[0-9]+\.[0-9]+).*/\1/p" "$INVENTORY" | head -n1)"

[[ -n "$BIP_ALL" ]] || echo "AVISO: no se encontró la línea 'bastion_fip:' en $ALL_YML" >&2
[[ -n "$BIP_INV" ]] || echo "AVISO: no se encontró la línea 'bastion-ops-01 ...' en $INVENTORY" >&2

if [[ -n "$BIP_ALL" && -n "$BIP_INV" && "$BIP_ALL" != "$BIP_INV" ]]; then
    echo "AVISO: los dos ficheros no apuntan a la misma IP ($BIP_ALL vs $BIP_INV)." >&2
fi

# ── Mostrar estado actual ─────────────────────────────────────────────────────
cat <<EOF

Los ficheros ansible/group_vars/all.yml y ansible/inventory.ini
tienen de IP flotante:
    [all.yml]       bastion_fip: $BIP_ALL
    [inventory.ini] bastion-ops-01 ansible_host=$BIP_INV
EOF

# ── Validación de IPv4 ────────────────────────────────────────────────────────
es_ip_valida() {
    local ip="$1" octeto
    [[ "$ip" =~ ^([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})$ ]] || return 1
    for octeto in "${BASH_REMATCH[@]:1}"; do
        (( 10#$octeto > 255 )) && return 1
    done
    return 0
}

# ── Pedir la nueva IP ─────────────────────────────────────────────────────────
while true; do
    read -r -p "Nueva IP que la sustituya? (IP or N to cancel): " NEW_IP
    NEW_IP="${NEW_IP%$'\r'}"   # elimina un posible CR (entrada desde Windows/Git Bash)

    case "$NEW_IP" in
        "" )              echo "No has escrito nada: escribe una IP o 'N' para cancelar." ;;
        [Nn] | [Nn][Oo] ) echo "Cancelado: no se ha modificado ningún fichero."; exit 0 ;;
        * )
            if es_ip_valida "$NEW_IP"; then
                break
            fi
            echo "'$NEW_IP' no es una IPv4 válida (ej. 156.35.98.87). Prueba de nuevo." >&2
            ;;
    esac
done

# ── Sustitución (solo si la línea existía con IP) ─────────────────────────────
[[ -n "$BIP_ALL" ]] && \
    sed -i -E "s|^bastion_fip:[[:space:]]*[0-9.]+|bastion_fip: $NEW_IP|" "$ALL_YML"
[[ -n "$BIP_INV" ]] && \
    sed -i -E "s|^(bastion-ops-01[[:space:]]+ansible_host=)[0-9.]+|\1$NEW_IP|" "$INVENTORY"

echo
echo "Hecho. IP flotante del bastión actualizada a $NEW_IP:"
[[ -n "$BIP_ALL" ]] && echo "    $ALL_YML     : $BIP_ALL -> $NEW_IP"
[[ -n "$BIP_INV" ]] && echo "    $INVENTORY   : $BIP_INV -> $NEW_IP"