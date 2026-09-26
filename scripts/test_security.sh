#!/usr/bin/env bash
# test_security.sh — Verificacion del perimetro (balanceo, WAF, rate limit, TLS).
# Uso:  LB_FIP=156.35.98.152 ./test_security.sh [--balancing|--waf|--rate|--tls|--failover|all]
# Desde el control node. Requiere: curl y openssl.
set -uo pipefail

LB_FIP="${LB_FIP:-}"
[[ -n "$LB_FIP" ]] || { echo "Usa: LB_FIP=<ip> $0"; exit 1; }
B="https://$LB_FIP"
C="curl -sk --max-time 5"
PASS=0
FAIL=0
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
  $C -o /dev/null -w '%{http_code}\n' --get --data-urlencode "id=UNION SELECT username,password FROM users" "$B/products" | grep -q 403 \
    && ok "SQLi UNION bloqueado (403)" || bad "SQLi UNION NO bloqueado"
  $C -o /dev/null -w '%{http_code}\n' --get --data-urlencode "q=<script>alert(1)</script>" "$B/products" | grep -q 403 \
    && ok "XSS bloqueado (403)" || bad "XSS NO bloqueado"
  $C -o /dev/null -w '%{http_code}\n' --get --data-urlencode "cmd=; cat /etc/passwd" "$B/products" | grep -q 403 \
    && ok "Inyeccion OS bloqueada (403)" || bad "Inyeccion OS NO bloqueada"
}

rate() {
  echo "== Rate limiting (60 peticiones en paralelo) =="
  local codes
  codes=$(seq 1 60 | xargs -P 40 -I{} $C -o /dev/null -w '%{http_code}\n' "$B/products" | sort | uniq -c)
  echo "$codes"
  echo "$codes" | grep -q "503" && ok "hay 503 (limite aplicado)" || bad "sin 503"
}

tls() {
  echo "== TLS endurecido =="
  local out
  echo | openssl s_client -connect "$LB_FIP:443" -tls1_2 </dev/null 2>/dev/null | grep -q "Cipher is" \
    && ok "TLSv1.2 OK" || bad "TLSv1.2 falla"
  out=$(echo | openssl s_client -connect "$LB_FIP:443" -tls1 </dev/null 2>&1)
  if echo "$out" | grep -q "Cipher is" && echo "$out" | grep -qi "TLSv1\\.0"; then
    bad "TLSv1.0 NO rechazado"
  else
    ok "TLSv1.0 rechazado"
  fi
  $C -sI "$B/" | grep -qi "strict-transport-security" && ok "HSTS presente" || bad "HSTS ausente"
}

failover() {
  echo "== Failover con caida de app-node-02 (manual, via bastion) =="
  note "1) Parar el mock:   ssh -o ProxyCommand=\"ssh -i ~/.ssh/Lab_project.pem -W %h:%p ubuntu@156.35.98.153\" -i ~/.ssh/Lab_project.pem ubuntu@10.10.99.22 'sudo systemctl stop mock-app.service'"
  note "2) Re-ejecutar:     ./test_security.sh --balancing  -> solo cantabrico-app-node-01 y codigos 200"
  note "3) Recuperar:       <mismo ssh> 'sudo systemctl start mock-app.service' y esperar fail_timeout (10s)"
  note "4) Re-ejecutar:     ./test_security.sh --balancing  -> reaparecen los dos nodos"
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
exit "$FAIL"