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

# ── Deteccion de procesos (portable en Android) ──────────────────────────────
# OJO: el `ps` de Android/toybox no soporta `-eo pid=,comm=,args=` como el de
# Linux de escritorio; ahi devuelve vacio y parece que no corre nada.
# /proc/<pid>/cmdline si funciona siempre.
find_app_pids() {
  for d in /proc/[0-9]*; do
    p=${d#/proc/}
    [ "$p" = "$$" ] && continue
    [ "$p" = "$PPID" ] && continue
    cmd=$(tr '\0' ' ' < "$d/cmdline" 2>/dev/null) || continue
    case "$cmd" in
      *diagnose_termux*|*run_termux*) continue ;;
      *python*expense_app_v2.py*) echo "$p" ;;
    esac
  done
}

find_cf_pids() {
  for d in /proc/[0-9]*; do
    p=${d#/proc/}
    cmd=$(tr '\0' ' ' < "$d/cmdline" 2>/dev/null) || continue
    case "$cmd" in
      *run_termux*|*diagnose_termux*) continue ;;
      *cloudflared*) echo "$p" ;;
    esac
  done
}

# Quien escucha en el puerto (independiente de como se haya arrancado)
port_busy() {
  python - "$1" <<'PY' 2>/dev/null
import socket, sys
s = socket.socket(); s.settimeout(1.5)
sys.exit(0 if s.connect_ex(('127.0.0.1', int(sys.argv[1]))) == 0 else 1)
PY
}


# ── Evitar dos instancias peleandose por la BD ────────────────────────────────
EXISTING=$(find_app_pids)
if [ -n "$EXISTING" ]; then
  say "ya hay un server corriendo (pid: $(echo $EXISTING)). Lo detengo para no duplicar."
  # shellcheck disable=SC2086
  kill $EXISTING 2>/dev/null; sleep 2
  # shellcheck disable=SC2086
  kill -9 $EXISTING 2>/dev/null; sleep 1
fi

# El puerto puede seguir ocupado por un proceso que no detectamos (por ejemplo
# uno arrancado desde otra sesion de Termux). Si no lo liberamos, el server
# nuevo no puede escuchar, muere al instante, y te sigue respondiendo el VIEJO
# con los bugs. Antes eso pasaba en silencio.
if port_busy "$PORT"; then
  say "el puerto $PORT sigue ocupado; intento liberarlo..."
  command -v fuser >/dev/null 2>&1 && fuser -k "$PORT/tcp" 2>/dev/null
  sleep 2
  if port_busy "$PORT"; then
    say "ERROR: el puerto $PORT sigue ocupado por otro proceso."
    say "       Ese proceso es el que te responde (probablemente codigo viejo)."
    say "       Opciones:"
    say "         pkg install psmisc && fuser -k $PORT/tcp"
    say "         o usa otro puerto:  XPNS_PORT=5003 ./run_termux.sh"
    say "         o cierra Termux del todo (deslizar en apps recientes) y reabre"
    exit 1
  fi
  say "puerto liberado"
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
