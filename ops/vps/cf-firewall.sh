#!/usr/bin/env bash
# Default-deny en la interfaz PUBLICA (ens6): bloquea TODO lo que entra de
# internet hacia containers, EXCEPTO 80/443 desde Cloudflare. Cierra de una los
# puertos publicados por accidente (3010/3011/8090/8095/8000/8080) y cualquiera
# futuro. Docker se saltea UFW -> filtramos en DOCKER-USER.
# NO afecta: SSH (INPUT), WireGuard 51820 (INPUT host), ni el trafico interno/WG.
# Pasar --persist para omitir la red de seguridad (uso en systemd/boot).
set -uo pipefail
[ "$(id -u)" = 0 ] || { echo "Correlo con sudo."; exit 1; }

PUBIF="ens6"
CF4="173.245.48.0/20 103.21.244.0/22 103.22.200.0/22 103.31.4.0/22 141.101.64.0/18 108.162.192.0/18 190.93.240.0/20 188.114.96.0/20 197.234.240.0/22 198.41.128.0/17 162.158.0.0/15 104.16.0.0/13 104.24.0.0/14 172.64.0.0/13 131.0.72.0/22"
CF6="2400:cb00::/32 2606:4700::/32 2803:f800::/32 2405:b500::/32 2405:8100::/32 2a06:98c0::/29 2c0f:f248::/32"

STAMP=$(date +%s)
BK4="/root/iptables-v4-$STAMP.bak"; BK6="/root/iptables-v6-$STAMP.bak"
iptables-save > "$BK4"; ip6tables-save > "$BK6"
echo "Backup: $BK4 / $BK6"

if [ "${1:-}" != "--persist" ]; then
  nohup bash -c "sleep 420; iptables-restore < '$BK4'; ip6tables-restore < '$BK6'; logger -t lockdown2 AUTO-REVERT" >/dev/null 2>&1 &
  echo ">>> SAFETY NET (PID $!): auto-revierte en 7 min. Si todo anda: sudo kill $!"
fi

apply() {
  local IPT="$1" CH="$2"; shift 2
  $IPT -L DOCKER-USER -n >/dev/null 2>&1 || { echo "  ($IPT) sin DOCKER-USER, omito"; return 0; }
  $IPT -N "$CH" 2>/dev/null || $IPT -F "$CH"
  $IPT -A "$CH" -m conntrack --ctstate ESTABLISHED,RELATED -j RETURN
  for c in "$@"; do $IPT -A "$CH" -p tcp -m multiport --dports 80,443 -s "$c" -j RETURN; done
  # LifeOS OTA: 80/443 abiertos al internet publico, no solo a Cloudflare.
  #
  # POR QUE. Un dispositivo que NO esta en la VPN tiene que poder instalar y
  # actualizar LifeOS y bajar los modelos. El del cerebro pesa 2.6 GB, y los
  # terminos de Cloudflare permiten cortar el CDN por servir "a disproportionate
  # percentage of ... other large files" en planes Free/Pro, asi que pasarlo por
  # el proxy naranja no es una salida. Medido: los paquetes de internet YA
  # llegan a esta maquina (los contadores RETURN de los rangos de Cloudflare
  # suben solos), asi que IONOS no bloquea nada en 80/443 — el unico que tiraba
  # el trafico era esta cadena.
  #
  # QUE SE PIERDE, dicho claro: un atacante puede ir directo a la IP y saltarse
  # el WAF/anti-DDoS de Cloudflare usando la cabecera Host, para CUALQUIER
  # dominio servido por el proxy de Coolify, no solo LifeOS. La IP de origen ya
  # era publica de todos modos: updates.lifeos.hectormr.com esta en DNS-only.
  #
  # LO QUE PROTEGE ARRIBA: nginx exige X-LifeOS-Update-Key en /manifest,
  # /download, /model/, /stt/, /tts/, /embed/ y /linux/, con limit_req y
  # limit_conn por IP (ops/ota/ota-root.conf). Esa llave viaja dentro del APK y
  # es extraible: es un guardarrail, no autenticacion.
  $IPT -A "$CH" -p tcp -m multiport --dports 80,443 \
    -m comment --comment "LifeOS: origen publico OTA/modelos (con llave en nginx)" \
    -j RETURN
  $IPT -A "$CH" -j DROP
  $IPT -D DOCKER-USER -i "$PUBIF" -j "$CH" 2>/dev/null || true
  $IPT -I DOCKER-USER 1 -i "$PUBIF" -j "$CH"
  echo "  ($IPT) default-deny en $PUBIF -> $CH"
}

# quitar las reglas viejas source-based (v1) si existen
iptables  -D DOCKER-USER -p tcp -m multiport --dports 80,443 -j CF-WG-WEB  2>/dev/null || true
ip6tables -D DOCKER-USER -p tcp -m multiport --dports 80,443 -j CF-WG-WEB6 2>/dev/null || true

apply iptables  PUBLIC-IN  $CF4
apply ip6tables PUBLIC-IN6 $CF6

# --- Bloqueo raw PREROUTING de puertos docker expuestos a 0.0.0.0 (menos 80/443) ---
# Cierra el bypass de docker-proxy/dockerd que sirve por INPUT (fuera de DOCKER-USER).
PUB=$(ss -tlnp 2>/dev/null | grep -oE '0.0.0.0:[0-9]+' | cut -d: -f2 | sort -un \
     | grep -vE '^(80|443|22)$' | tr '\n' ',' | sed 's/,$//')
if [ -n "$PUB" ]; then
  iptables -t raw -D PREROUTING -i ens6 -p tcp -m multiport --dports "$PUB" -j DROP 2>/dev/null || true
  iptables -t raw -I PREROUTING -i ens6 -p tcp -m multiport --dports "$PUB" -j DROP
  echo "  raw PREROUTING DROP (ens6): $PUB"
fi

echo ""
echo "LISTO. Verifica AHORA:"
echo "  - publico:  https://yax.hectormr.com  (debe cargar)"
echo "  - tu WG:    los paneles por dominio siguen"
echo "Si todo anda, cancela el revert y hazlo permanente:"
echo "  sudo kill \$(pgrep -f 'sleep 420')                       # 1) cancela auto-revert"
echo "  sudo install -m 755 $0 /usr/local/bin/cf-firewall.sh    # 2) reemplaza el v1"
echo "  sudo sed -i 's# --persist##; s#cf-firewall.sh#cf-firewall.sh --persist#' /etc/systemd/system/cf-firewall.service  # 3) boot sin safety-net"
echo "  sudo systemctl daemon-reload                            # 4)"
