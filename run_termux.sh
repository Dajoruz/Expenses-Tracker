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
# Toda la cadena de ancestros (shell que nos lanzo, su shell, etc.).
# Sin esto podriamos matar al proceso que nos esta ejecutando si su linea de
# comandos menciona el script — pasa al lanzarlo como `bash run_termux.sh`.
ancestors() {
  a=$$
  while [ -n "$a" ] && [ "$a" != "0" ] && [ "$a" != "1" ]; do
    echo "$a"
    a=$(awk '{print $4}' "/proc/$a/stat" 2>/dev/null)
  done
}
ANCESTORS=" $(ancestors | tr '\n' ' ') "

is_ancestor() { case "$ANCESTORS" in *" $1 "*) return 0 ;; *) return 1 ;; esac; }

find_app_pids() {
  for d in /proc/[0-9]*; do
    p=${d#/proc/}
    is_ancestor "$p" && continue
    # Solo los primeros 3 argumentos (ejecutable + script), no toda la
    # linea: si no, una shell que solo MENCIONA el nombre se cuenta como match.
    cmd=$(tr '\0' '\n' < "$d/cmdline" 2>/dev/null | head -3 | tr '\n' ' ') || continue
    case "$cmd" in
      *diagnose_termux*|*run_termux*) continue ;;
      *python*expense_app_v2.py*) echo "$p" ;;
    esac
  done
}

find_sup_pids() {
  for d in /proc/[0-9]*; do
    p=${d#/proc/}
    is_ancestor "$p" && continue
    # Solo los primeros 2 argumentos (ejecutable + script), no toda la
    # linea: si no, una shell que solo MENCIONA el nombre se cuenta como match.
    cmd=$(tr '\0' '\n' < "$d/cmdline" 2>/dev/null | head -2 | tr '\n' ' ') || continue
    case "$cmd" in
      *run_termux.sh*) echo "$p" ;;
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
# Otros supervisores vivos. Si no los matamos, cada uno relanza SU app y se
# pelean por el puerto en un bucle infinito de "Address already in use".
OTHER_SUP=$(find_sup_pids)
if [ -n "$OTHER_SUP" ]; then
  say "hay otro run_termux.sh corriendo (pid: $(echo $OTHER_SUP)). Lo detengo."
  # shellcheck disable=SC2086
  kill $OTHER_SUP 2>/dev/null; sleep 2
  # shellcheck disable=SC2086
  kill -9 $OTHER_SUP 2>/dev/null; sleep 1
  EXISTING=$(find_app_pids)
fi

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

APP_PID=""; CF_PID=""; APP_STARTED_AT=0
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
# Historial de reinicios, para no relanzar en bucle infinito
RESTARTS=0
FIRST_RESTART=0

free_port_or_fail() {
  # Relanzar sin comprobar el puerto es lo que producia el bucle infinito de
  # "OSError: [Errno 98] Address already in use" cada 15 segundos.
  port_busy "$PORT" || return 0
  say "el puerto $PORT esta ocupado; intento liberarlo..."
  # shellcheck disable=SC2086
  kill $(find_app_pids) 2>/dev/null; sleep 2
  command -v fuser >/dev/null 2>&1 && fuser -k "$PORT/tcp" 2>/dev/null
  sleep 2
  if port_busy "$PORT"; then
    say ""
    say "ERROR: el puerto $PORT sigue ocupado por un proceso que no puedo matar."
    say "       Relanzar no sirve de nada, asi que me detengo aqui."
    say "       Prueba:"
    say "         pkg install psmisc && fuser -k $PORT/tcp"
    say "         XPNS_PORT=5003 ./run_termux.sh"
    say "         o cierra Termux del todo (apps recientes) y vuelve a abrir"
    return 1
  fi
  say "puerto liberado"
  return 0
}

start_app() {
  free_port_or_fail || { cleanup_fail; }
  python expense_app_v2.py >>"$LOGDIR/xpns.log" 2>&1 &
  APP_PID=$!
  APP_STARTED_AT=$(date +%s)
  say "server arrancado (pid $APP_PID)"
}

cleanup_fail() {
  [ -n "${CF_PID:-}" ] && kill "$CF_PID" 2>/dev/null
  command -v termux-wake-unlock >/dev/null 2>&1 && termux-wake-unlock
  exit 1
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
    NOW=$(date +%s)
    LIVED=$(( NOW - APP_STARTED_AT ))

    # Si murio casi al instante, es un fallo de arranque (puerto ocupado,
    # dependencia rota, BD ilegible): relanzar en bucle solo llena el log.
    if [ "$LIVED" -lt 20 ]; then
      [ "$RESTARTS" -eq 0 ] && FIRST_RESTART=$NOW
      RESTARTS=$(( RESTARTS + 1 ))
    else
      RESTARTS=0   # vivio un rato: caida normal, el contador se reinicia
    fi

    if [ "$RESTARTS" -ge 5 ]; then
      say ""
      say "=================================================================="
      say "EL SERVER MURIO 5 VECES SEGUIDAS AL ARRANCAR (en $(( NOW - FIRST_RESTART ))s)."
      say "No lo relanzo mas: el problema no se arregla reintentando."
      say "Ultimas lineas del error:"
      tail -n 25 "$LOGDIR/xpns.log" | sed 's/^/       /'
      say ""
      say "Si dice 'Address already in use': otro proceso tiene el puerto $PORT."
      say "  pkg install psmisc && fuser -k $PORT/tcp"
      say "  o:  XPNS_PORT=5003 ./run_termux.sh"
      say "Diagnostico completo:  ./diagnose_termux.sh"
      say "=================================================================="
      cleanup_fail
    fi

    say "el server se cayo (eso es el 502) — relanzando (intento $RESTARTS)..."
    tail -n 8 "$LOGDIR/xpns.log" | sed 's/^/       /'
    [ "$RESTARTS" -gt 1 ] && sleep $(( RESTARTS * 3 ))   # backoff
    start_app
  fi
  if [ "$TUNNEL" = "1" ] && [ -n "$CF_PID" ] && ! kill -0 "$CF_PID" 2>/dev/null; then
    say "cloudflared se cayo (eso es el Error 1033) — relanzando..."
    tail -n 10 "$LOGDIR/cloudflared.log" | sed 's/^/       /'
    start_tunnel
  fi
done
