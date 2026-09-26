#!/usr/bin/env bash
#
# change_bastion_fip.sh
#
# Sustituye la IP flotante (FIP) pública del bastión allí donde esté anclada:
#
#   ansible/group_vars/all.yml  -->  línea  bastion_fip: <IP>
#   ansible/inventory.ini       -->  línea  bastion-ops-01 ansible_host=<IP>
#   terraform/terraform.tfvars  -->  línea  bastion_floating_ip = "<IP>"   (si existe)
#
# Además, si existe terraform/terraform.tfvars, hace una segunda pregunta por
# la IP flotante del load balancer (red DMZ) y actualiza la línea:
#
#   terraform/terraform.tfvars  -->  línea  lb_floating_ip = "<IP>"
#
# Uso:
#   scripts/change_bastion_fip.sh
#
# El script muestra las líneas actuales con su IP y pide la/las nuevas.
# Responder "N" (o "no") en una pregunta cancela (exit 0 sin cambios).

set -euo pipefail

# ── Rutas (relativas a la raíz del repo) ──────────────────────────────────────
BASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ALL_YML="$BASE_DIR/ansible/group_vars/all.yml"
INVENTORY="$BASE_DIR/ansible/inventory.ini"
TFVARS="$BASE_DIR/terraform/terraform.tfvars"

# ── Comprobaciones previas ────────────────────────────────────────────────────
for f in "$ALL_YML" "$INVENTORY"; do
    [[ -f "$f" ]] || { echo "ERROR: no se encuentra el fichero: $f" >&2; exit 1; }
done

TF_EXISTE=0
if [[ -f "$TFVARS" ]]; then
    TF_EXISTE=1
else
    echo "AVISO: no se encuentra $TFVARS; se omiten bastion_floating_ip y lb_floating_ip." >&2
fi

# ── IP actuales ───────────────────────────────────────────────────────────────
BIP_ALL="$(sed -nE 's/^bastion_fip:[[:space:]]*([0-9]+\.[0-9]+\.[0-9]+\.[0-9]+).*/\1/p' "$ALL_YML" | head -n1)"
BIP_INV="$(sed -nE 's/^bastion-ops-01[[:space:]]+ansible_host=([0-9]+\.[0-9]+\.[0-9]+\.[0-9]+).*/\1/p' "$INVENTORY" | head -n1)"
BIP_TF=""
LB_TF=""
if [[ $TF_EXISTE -eq 1 ]]; then
    BIP_TF="$(sed -nE 's|^bastion_floating_ip[[:space:]]*=[[:space:]]*"([0-9]+\.[0-9]+\.[0-9]+\.[0-9]+)".*|\1|p' "$TFVARS" | head -n1)"
    LB_TF="$(sed -nE 's|^lb_floating_ip[[:space:]]*=[[:space:]]*"([0-9]+\.[0-9]+\.[0-9]+\.[0-9]+)".*|\1|p' "$TFVARS" | head -n1)"
fi

[[ -n "$BIP_ALL" ]] || echo "AVISO: no se encontró la línea 'bastion_fip:' en $ALL_YML" >&2
[[ -n "$BIP_INV" ]] || echo "AVISO: no se encontró la línea 'bastion-ops-01 ...' en $INVENTORY" >&2
if [[ $TF_EXISTE -eq 1 ]]; then
    [[ -n "$BIP_TF" ]] || echo "AVISO: no se encontró 'bastion_floating_ip' en $TFVARS" >&2
    [[ -n "$LB_TF"  ]] || echo "AVISO: no se encontró 'lb_floating_ip' en $TFVARS" >&2
fi

# Aviso si las fuentes de bastión están desincronizadas
BIPS=()
[[ -n "$BIP_ALL" ]] && BIPS+=("$BIP_ALL")
[[ -n "$BIP_INV" ]] && BIPS+=("$BIP_INV")
[[ -n "$BIP_TF"  ]] && BIPS+=("$BIP_TF")
if (( ${#BIPS[@]} > 1 )); then
    DISTINTAS="$(printf '%s\n' "${BIPS[@]}" | sort -u | wc -l)"
    if (( DISTINTAS > 1 )); then
        echo "AVISO: las fuentes de la IP de bastión no apuntan a la misma IP: ${BIPS[*]}." >&2
    fi
fi

# ── Mostrar estado actual ─────────────────────────────────────────────────────
cat <<EOF

Los ficheros que contienen la IP flotante son los siguientes (estado actual):

  Bastión:
    [all.yml]          bastion_fip: $BIP_ALL
    [inventory.ini]    bastion-ops-01 ansible_host=$BIP_INV
EOF
if [[ $TF_EXISTE -eq 1 ]]; then
    echo "    [terraform.tfvars]  bastion_floating_ip = \"$BIP_TF\""
    echo
    echo "  Load balancer (DMZ):"
    if [[ -n "$LB_TF" ]]; then
        echo "    [terraform.tfvars]  lb_floating_ip = \"$LB_TF\""
    else
        echo "    [terraform.tfvars]  lb_floating_ip = (línea no encontrada)"
    fi
fi

# ── Validación de IPv4 ────────────────────────────────────────────────────────
es_ip_valida() {
    local ip="$1" octeto
    [[ "$ip" =~ ^([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})$ ]] || return 1
    for octeto in "${BASH_REMATCH[@]:1}"; do
        (( 10#$octeto > 255 )) && return 1
    done
    return 0
}

# ── Petición de una IP (guarda el resultado en la global $RESPUESTA) ─────────
# NOTA: no usar $(...) aquí; el exit en case de cancelar debe afectar al script.
RESPUESTA=""
pide_ip() {   # $1 = prompt, $2 = mensaje si se cancela
    local prompt="$1" cancel_msg="$2" nueva
    while true; do
        read -r -p "$prompt" nueva
        nueva="${nueva%$'\r'}"   # elimina un posible CR (entrada desde Windows/Git Bash)

        case "$nueva" in
            "" )              echo "No has escrito nada: escribe una IP o 'N' para cancelar." ;;
            [Nn] | [Nn][Oo] ) echo "$cancel_msg"; exit 0 ;;
            * )
                if es_ip_valida "$nueva"; then
                    RESPUESTA="$nueva"
                    return 0
                fi
                echo "'$nueva' no es una IPv4 válida (ej. 156.35.98.87). Prueba de nuevo." >&2
                ;;
        esac
    done
}

# ── Sustitución de una línea (solo si existe y la IP cambia de verdad) ────────
cambia_linea() {  # $1 = fichero, $2 = IP actual, $3 = IP nueva, $4 = script sed
    local f="$1" vieja="$2" nueva="$3" sed_cmd="$4"
    if [[ -z "$vieja" ]]; then
        echo "    $f        : línea no encontrada (sin cambios)"
        return 0
    fi
    if [[ "$nueva" == "$vieja" ]]; then
        echo "    $f        : ya apunta a $nueva (sin cambios)"
        return 0
    fi
    sed -i -E "$sed_cmd" "$f"
    echo "    $f        : $vieja -> $nueva"
}

# ── Pregunta 1: IP del bastión ────────────────────────────────────────────────
echo
pide_ip "Nueva IP del bastión que la sustituya? (IP or N to cancel): " \
    "Cancelado: no se ha modificado ningún fichero."
NEW_BIP="$RESPUESTA"

echo
echo "Hecho. IP flotante del bastión actualizada:"
cambia_linea "$ALL_YML" "$BIP_ALL" "$NEW_BIP" \
    "s|^bastion_fip:[[:space:]]*[0-9.]+|bastion_fip: $NEW_BIP|"
cambia_linea "$INVENTORY" "$BIP_INV" "$NEW_BIP" \
    "s|^(bastion-ops-01[[:space:]]+ansible_host=)[0-9.]+|\1$NEW_BIP|"
if [[ $TF_EXISTE -eq 1 ]]; then
    cambia_linea "$TFVARS" "$BIP_TF" "$NEW_BIP" \
        "s|^(bastion_floating_ip[[:space:]]*=[[:space:]]*)\"[0-9.]+\"|\1\"$NEW_BIP\"|"
fi

# ── Pregunta 2: IP del load balancer (solo si hay tfvars con esa línea) ───────
if [[ $TF_EXISTE -eq 1 ]]; then
    if [[ -n "$LB_TF" ]]; then
        echo
        pide_ip "Nueva IP del load balancer que la sustituya? (IP or N to cancel): " \
            "Cancelado el cambio del load balancer (la IP del bastión ya está actualizada)."
        NEW_LB="$RESPUESTA"
        echo
        echo "Hecho. IP flotante del load balancer actualizada:"
        cambia_linea "$TFVARS" "$LB_TF" "$NEW_LB" \
            "s|^(lb_floating_ip[[:space:]]*=[[:space:]]*)\"[0-9.]+\"|\1\"$NEW_LB\"|"
    else
        echo
        echo "Se omite la segunda pregunta: no hay línea 'lb_floating_ip' que actualizar." >&2
    fi
fi

echo