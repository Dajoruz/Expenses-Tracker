#!/data/data/com.termux/files/usr/bin/bash
#
# Arranque de XPNS v3 en Termux, con el tunel de Cloudflare.
#
# Resuelve las tres razones por las que esto se cae solo en un telefono:
#   1. Android congela Termux al apagar la pantalla   -> termux-wake-lock
#   2. El server de XPNS se muere                     -> se relanza (502)
#   3. cloudflared se muere                           -> se relanza (Error 1033)
#
#   chmod +x run_termux.sh && ./run_termux.sh
#
# Solo la app, sin tunel:   XPNS_TUNNEL=0 ./run_termux.sh
#
set -u
cd "$(dirname "$0")" || exit 1

PORT="${XPNS_PORT:-5002}"
TUNNEL="${XPNS_TUNNEL:-1}"
export XPNS_PORT="$PORT"
LOGDIR="$PWD/logs"; mkdir -p "$LOGDIR"

say(){ echo "[xpns] $*"; }

# ── Evitar dos instancias peleandose por la BD ────────────────────────────────
EXISTING=$(ps -eo pid=,comm=,args= 2>/dev/null | awk -v self="$$" -v par="$PPID" '
  $1 != self && $1 != par && $2 ~ /^python/ && $0 ~ /expense_app_v2\.py/ { print $1 }')
if [ -n "$EXISTING" ]; then
  say "ya hay un server corriendo (pid: $(echo $EXISTING)). Lo detengo para no duplicar."
  # shellcheck disable=SC2086
  kill $EXISTING 2>/dev/null; sleep 2
  kill -9 $EXISTING 2>/dev/null
fi

# ── 1. Wake lock ──────────────────────────────────────────────────────────────
if command -v termux-wake-lock >/dev/null 2>&1; then
  termux-wake-lock && say "wake lock activado (sigue vivo con la pantalla apagada)"
else
  say "AVISO: termux-wake-lock no encontrado -> pkg install termux-api"
  say "       Sin el, Android detendra todo al apagar la pantalla."
fi
say "Recuerda poner Termux en bateria 'Sin restricciones' en Ajustes de Android."

APP_PID=""; CF_PID=""
cleanup() {
  echo ""; say "cerrando..."
  [ -n "$APP_PID" ] && kill "$APP_PID" 2>/dev/null
  [ -n "$CF_PID"  ] && kill "$CF_PID"  2>/dev/null
  command -v termux-wake-unlock >/dev/null 2>&1 && termux-wake-unlock
  exit 0
}
trap cleanup INT TERM

# ── 2. Dependencias ───────────────────────────────────────────────────────────
python -c "import flask, flask_sqlalchemy, flask_cors" 2>/dev/null || {
  say "instalando dependencias..."; pip install -r requirements.txt; }
python -c "import waitress" 2>/dev/null || {
  say "instalando waitress..."; pip install waitress; }

IP=$(ip route get 1 2>/dev/null | awk '{print $7; exit}')
say "local   : http://127.0.0.1:$PORT"
[ -n "${IP:-}" ] && say "en la red: http://$IP:$PORT"
say "logs    : $LOGDIR/"
say "Ctrl+C para detener"
echo ""

# ── 3. Supervisor: mantiene vivos la app y el tunel ───────────────────────────
start_app() {
  python expense_app_v2.py >>"$LOGDIR/xpns.log" 2>&1 &
  APP_PID=$!
  say "server arrancado (pid $APP_PID)"
}

start_tunnel() {
  [ "$TUNNEL" = "1" ] || return 0
  command -v cloudflared >/dev/null 2>&1 || {
    say "cloudflared no instalado — sin tunel (la app sigue en la red local)"; TUNNEL=0; return 0; }
  # Con ~/.cloudflared/config.yml, 'tunnel run' toma el tunel de ahi.
  if [ -f "$HOME/.cloudflared/config.yml" ] || [ -f "$HOME/.cloudflared/config.yaml" ]; then
    cloudflared tunnel run >>"$LOGDIR/cloudflared.log" 2>&1 &
  else
    say "sin ~/.cloudflared/config.yml — levantando tunel rapido (URL temporal)"
    cloudflared tunnel --url "http://127.0.0.1:$PORT" >>"$LOGDIR/cloudflared.log" 2>&1 &
  fi
  CF_PID=$!
  say "cloudflared arrancado (pid $CF_PID)"
}

start_app
sleep 4
start_tunnel

while true; do
  sleep 15
  if ! kill -0 "$APP_PID" 2>/dev/null; then
    say "el server se cayo (eso es el 502) — relanzando..."
    tail -n 15 "$LOGDIR/xpns.log" | sed 's/^/       /'
    start_app
  fi
  if [ "$TUNNEL" = "1" ] && [ -n "$CF_PID" ] && ! kill -0 "$CF_PID" 2>/dev/null; then
    say "cloudflared se cayo (eso es el Error 1033) — relanzando..."
    tail -n 10 "$LOGDIR/cloudflared.log" | sed 's/^/       /'
    start_tunnel
  fi
done
