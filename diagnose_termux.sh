#!/data/data/com.termux/files/usr/bin/bash
#
# Diagnostico de XPNS en Termux.
#   chmod +x diagnose_termux.sh && ./diagnose_termux.sh
# Pega la salida completa si necesitas ayuda.
#
cd "$(dirname "$0")" || exit 1
DB="${XPNS_DB:-xpns_v3.db}"
PORT="${XPNS_PORT:-5002}"
ok(){ echo "  [OK]   $*"; }
bad(){ echo "  [FALLA] $*"; }
warn(){ echo "  [AVISO] $*"; }
hdr(){ echo ""; echo "=== $* ==="; }

# ── Deteccion de procesos (portable en Android) ──────────────────────────────
# OJO: el `ps` de Android/toybox no soporta `-eo pid=,comm=,args=` como el de
# Linux de escritorio; ahi devuelve vacio y parece que no corre nada.
# /proc/<pid>/cmdline si funciona siempre.
find_app_pids() {
  for d in /proc/[0-9]*; do
    p=${d#/proc/}
    [ "$p" = "$$" ] && continue
    [ "$p" = "$PPID" ] && continue
    # Solo los primeros 3 argumentos (ejecutable + script), no toda la
    # linea: si no, una shell que solo MENCIONA el nombre se cuenta como match.
    cmd=$(tr '\0' '\n' < "$d/cmdline" 2>/dev/null | head -3 | tr '\n' ' ') || continue
    case "$cmd" in
      *diagnose_termux*|*run_termux*) continue ;;
      *python*expense_app_v2.py*) echo "$p" ;;
    esac
  done
}

find_cf_pids() {
  for d in /proc/[0-9]*; do
    p=${d#/proc/}
    # Solo los primeros 2 argumentos (ejecutable + script), no toda la
    # linea: si no, una shell que solo MENCIONA el nombre se cuenta como match.
    cmd=$(tr '\0' '\n' < "$d/cmdline" 2>/dev/null | head -2 | tr '\n' ' ') || continue
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


echo "======================================================"
echo " XPNS — diagnostico Termux    $(date)"
echo "======================================================"

hdr "1. Entorno"
echo "  carpeta : $(pwd)"
echo "  python  : $(python -V 2>&1)"
python - <<'PY' 2>/dev/null || warn "faltan dependencias: pip install -r requirements.txt"
import importlib
from importlib.metadata import version, PackageNotFoundError
DIST = {'flask':'Flask','flask_sqlalchemy':'Flask-SQLAlchemy','flask_cors':'Flask-Cors',
        'werkzeug':'Werkzeug','sqlalchemy':'SQLAlchemy','waitress':'waitress'}
for m, dist in DIST.items():
    try:
        importlib.import_module(m)
    except ImportError:
        print(f"  {m:18s} NO INSTALADO"); continue
    try:
        v = version(dist)
    except PackageNotFoundError:
        v = '(instalado)'
    print(f"  {m:18s} {v}")
PY

hdr "2. Espacio en disco"
df -h "$HOME" 2>/dev/null | tail -n +1
AVAIL=$(df -P "$HOME" 2>/dev/null | awk 'NR==2{print $4}')
[ -n "$AVAIL" ] && [ "$AVAIL" -lt 51200 ] 2>/dev/null \
  && bad "queda menos de 50 MB — SQLite NO puede escribir sin espacio" \
  || ok "hay espacio libre"

hdr "3. La base de datos"
if [ ! -f "$DB" ]; then
  bad "no existe $DB en $(pwd)"
else
  ok "existe: $(ls -la "$DB" | awk '{print $1, $3":"$4, $5" bytes"}')"
  # /sdcard rompe WAL y a veces las escrituras
  case "$(readlink -f "$DB")" in
    /storage/*|/sdcard/*|*/storage/shared/*|/mnt/*)
      bad "el .db esta en ALMACENAMIENTO COMPARTIDO."
      echo "         SQLite NO funciona bien ahi (WAL y bloqueos fallan)."
      echo "         Muevelo al almacenamiento interno de Termux:"
      echo "           mv $DB ~/projects/expense-tracker-v2/" ;;
    *) ok "esta en el almacenamiento interno de Termux (correcto)" ;;
  esac
  # -wal y -shm son normales mientras el server corre en modo WAL.
  # -journal en cambio delata un cierre abrupto (bateria a 0, proceso matado).
  [ -f "$DB-journal" ] && warn "existe $DB-journal — resto de un cierre abrupto; SQLite lo recuperara si puede escribir"
  if [ -f "$DB-wal" ]; then
    WSZ=$(stat -c%s "$DB-wal" 2>/dev/null || echo 0)
    [ "$WSZ" -gt 52428800 ] 2>/dev/null \
      && warn "$DB-wal es grande ($WSZ bytes): no se esta haciendo checkpoint" \
      || ok "$DB-wal presente ($WSZ bytes) — normal en modo WAL"
  fi
  echo "  --- prueba de LECTURA y ESCRITURA real ---"
  python - "$DB" <<'PY'
import sqlite3, sys, os
db = sys.argv[1]
try:
    c = sqlite3.connect(db, timeout=10)
    n = c.execute("select count(*) from expenses").fetchone()[0]
    u = c.execute("select count(*) from users").fetchone()[0]
    print(f"  [OK]   LECTURA: {u} usuarios, {n} gastos")
except Exception as e:
    print(f"  [FALLA] LECTURA: {e}"); sys.exit()
try:
    c.execute("create table if not exists _diag (k integer)")
    c.execute("insert into _diag values (1)")
    c.commit(); c.execute("drop table _diag"); c.commit()
    print("  [OK]   ESCRITURA: se pudo escribir")
except Exception as e:
    print(f"  [FALLA] ESCRITURA: {e}")
    print("         <-- ESTA ES LA CAUSA DE QUE VEAS LOS GASTOS VIEJOS")
    print("             PERO NO PUEDAS GUARDAR NUEVOS")
try:
    m = c.execute("pragma journal_mode=WAL").fetchone()[0]
    print(f"  {'[OK]  ' if m.lower()=='wal' else '[AVISO]'} journal_mode -> {m}"
          + ("" if m.lower()=='wal' else "  (este sistema de archivos no soporta WAL)"))
except Exception as e:
    print(f"  [AVISO] PRAGMA journal_mode fallo: {e}")
try:
    print(f"  integridad: {c.execute('pragma quick_check').fetchone()[0]}")
except Exception as e:
    print(f"  [FALLA] integridad: {e}")
PY
fi

hdr "4. El server de XPNS"
# Solo procesos python de verdad; excluye esta shell, su padre y el propio
# diagnostico (si no, el script se cuenta a si mismo y reporta copias de mas).
PIDS=$(find_app_pids | tr '\n' ' ')
PIDS=$(echo $PIDS)
if [ -n "$PIDS" ]; then
  ok "corriendo (pid: $PIDS)"
  N=$(echo "$PIDS" | wc -w)
  [ "$N" -gt 1 ] && bad "hay $N copias corriendo a la vez — se pelean por la BD. pkill -f 'python.*expense_app_v2'"
else
  if port_busy "$PORT"; then
    bad "no detecto el proceso, PERO algo esta escuchando en el puerto $PORT."
    echo "         Es un server que no arranco desde aqui (o de una version vieja)."
    echo "         Matalo antes de relanzar:"
    echo "           fuser -k $PORT/tcp   # o reinicia Termux por completo"
  else
    bad "NO esta corriendo  ->  esto es lo que causa el 502 de Cloudflare"
  fi
fi
if command -v curl >/dev/null 2>&1; then
  H=$(curl -s -m 10 "http://127.0.0.1:$PORT/api/health" 2>&1)
  if [ -n "$H" ]; then
    echo "  /api/health: $H"
    if echo "$H" | grep -q '"db_writable"'; then
      echo "$H" | grep -q '"db_writable": *true' \
        && ok "la BD acepta escrituras" \
        || bad "la BD NO acepta escrituras (mira write_error arriba)"
    else
      warn "este server es de una version vieja (sin db_writable)."
      echo "         Actualiza el codigo y reinicia:  pkill -f 'python.*expense_app_v2' && ./run_termux.sh"
    fi
  else
    bad "no responde en http://127.0.0.1:$PORT"
  fi
fi

hdr "5. Cloudflare Tunnel"
if command -v cloudflared >/dev/null 2>&1; then
  ok "cloudflared instalado: $(cloudflared --version 2>&1 | head -1)"
  CFP=$(find_cf_pids | tr '\n' ' ')
  if [ -n "$(echo $CFP)" ]; then
    ok "cloudflared corriendo (pid: $(echo $CFP))"
  else
    bad "cloudflared NO esta corriendo  ->  esto causa el Error 1033"
  fi
  for f in ~/.cloudflared/config.yml ~/.cloudflared/config.yaml /etc/cloudflared/config.yml; do
    if [ -f "$f" ]; then
      echo "  --- $f ---"
      sed 's/^/    /' "$f"
      grep -qE "127\.0\.0\.1:$PORT|localhost:$PORT" "$f" \
        && ok "el tunel apunta al puerto $PORT (correcto)" \
        || bad "el tunel NO apunta a http://127.0.0.1:$PORT — revisa 'service:'"
    fi
  done
else
  warn "cloudflared NO esta en el PATH de este Termux."
  echo "         Pero dajorus.com es un tunel, asi que corre desde otro lado."
  echo "         Buscalo:"
  echo "           ls -la ~/.cloudflared/ 2>/dev/null"
  echo "           ls -la ~/cloudflared* ./cloudflared* 2>/dev/null"
  CFP=$(find_cf_pids | tr '\n' ' ')
  [ -n "$(echo $CFP)" ] && warn "hay un proceso cloudflared vivo (pid: $(echo $CFP)) fuera del PATH"
  echo "         Para instalarlo aqui:  pkg install cloudflared"
fi

hdr "6. Bateria y wake lock"
if command -v termux-wake-lock >/dev/null 2>&1; then
  ok "termux-api instalado (termux-wake-lock disponible)"
else
  bad "termux-api NO instalado  ->  Android congela el server al apagar la pantalla"
  echo "         pkg install termux-api"
fi
echo "  IMPORTANTE: en Ajustes de Android, en la app Termux,"
echo "  pon la bateria en 'Sin restricciones' / 'No optimizar'."
echo "  Si no, Android mata Termux al rato y se cae el server Y el tunel."

hdr "Resumen"
echo "  502 Bad Gateway  = el tunel vive pero el server de XPNS esta caido"
echo "  Error 1033       = cloudflared no esta corriendo"
echo "  Ver datos viejos pero no guardar nuevos = la BD esta en solo lectura"
echo ""
echo "  Para levantar todo:  ./run_termux.sh"
echo "======================================================"
