#!/data/data/com.termux/files/usr/bin/bash
#
# Recoge TODA la info de diagnostico de XPNS en un solo archivo.
#
#   chmod +x collect_info.sh && ./collect_info.sh
#
# Nunca se detiene: si un comando falla, lo anota y sigue con el siguiente.
# Al final deja todo en  xpns_info.txt  para que lo copies de una sola vez.
#
# Las credenciales del tunel (tokens, .json, secrets) se CENSURAN.
#
cd "$(dirname "$0")" 2>/dev/null || cd .
OUT="$PWD/xpns_info.txt"
PORT="${XPNS_PORT:-5002}"
DB="${XPNS_DB:-xpns_v3.db}"
PY=$(command -v python || command -v python3 || echo python)

: > "$OUT"
say(){ printf '%s\n' "$*" | tee -a "$OUT"; }

# run <titulo> <comando...>  — captura salida y errores, nunca aborta
run(){
  t="$1"; shift
  printf '\n----- %s -----\n' "$t" >> "$OUT"
  if out=$("$@" 2>&1); then
    printf '%s\n' "${out:-(sin salida)}" >> "$OUT"
  else
    printf '(fallo, codigo %s)\n%s\n' "$?" "${out:-(sin salida)}" >> "$OUT"
  fi
}
# runsh <titulo> <linea de shell>  — igual pero permite pipes y redirecciones
runsh(){
  t="$1"; shift
  printf '\n----- %s -----\n' "$t" >> "$OUT"
  out=$(eval "$*" 2>&1); rc=$?
  [ $rc -ne 0 ] && printf '(codigo %s)\n' "$rc" >> "$OUT"
  printf '%s\n' "${out:-(sin salida)}" >> "$OUT"
}

say "Recogiendo informacion de XPNS... (esto no falla, aunque algo de error)"
say ""

{
  echo "=================================================================="
  echo " XPNS — informe de diagnostico"
  echo " fecha  : $(date 2>/dev/null)"
  echo " puerto : $PORT"
  echo " carpeta: $PWD"
  echo "=================================================================="
} >> "$OUT"

# ── 1. Sistema ───────────────────────────────────────────────────────────────
run  "uname"            uname -a
runsh "android"         'getprop ro.build.version.release 2>/dev/null; getprop ro.product.model 2>/dev/null'
runsh "termux"          'echo "PREFIX=$PREFIX"; echo "HOME=$HOME"; echo "SHELL=$SHELL"'
run  "python"           "$PY" -V
runsh "paquetes python" "$PY - <<'PY'
from importlib.metadata import version, PackageNotFoundError
import importlib
for m, d in [('flask','Flask'),('flask_sqlalchemy','Flask-SQLAlchemy'),
             ('flask_cors','Flask-Cors'),('werkzeug','Werkzeug'),
             ('sqlalchemy','SQLAlchemy'),('waitress','waitress')]:
    try:
        importlib.import_module(m)
    except Exception as e:
        print('%-18s NO IMPORTA (%s)' % (m, e)); continue
    try: print('%-18s %s' % (m, version(d)))
    except PackageNotFoundError: print('%-18s (instalado)' % m)
PY"

# ── 2. Repo ──────────────────────────────────────────────────────────────────
runsh "git"             'git rev-parse --abbrev-ref HEAD; git log --oneline -3; git status --short'
run  "archivos"         ls -la

# ── 3. Base de datos ─────────────────────────────────────────────────────────
runsh "espacio"         'df -h "$HOME"'
runsh "db archivos"     'ls -la '"$DB"'* 2>/dev/null || echo "no existe '"$DB"'"'
runsh "db ruta real"    'readlink -f '"$DB"' 2>/dev/null'
runsh "db lectura/escritura" "$PY - '$DB' <<'PY'
import sqlite3, sys, os
db = sys.argv[1]
if not os.path.exists(db):
    print('NO EXISTE:', db); raise SystemExit
try:
    c = sqlite3.connect(db, timeout=10)
    print('usuarios :', c.execute('select count(*) from users').fetchone()[0])
    print('gastos   :', c.execute('select count(*) from expenses').fetchone()[0])
    print('LECTURA  : OK')
except Exception as e:
    print('LECTURA  : FALLA ->', e); raise SystemExit
try:
    c.execute('create table if not exists _diag (k integer)')
    c.execute('insert into _diag values (1)'); c.commit()
    c.execute('drop table _diag'); c.commit()
    print('ESCRITURA: OK')
except Exception as e:
    print('ESCRITURA: FALLA ->', e)
for p in ('journal_mode','quick_check','page_size','user_version'):
    try: print('%-13s:' % p, c.execute('pragma %s' % p).fetchone()[0])
    except Exception as e: print('%-13s: error %s' % (p, e))
PY"

# ── 4. Procesos y puertos ────────────────────────────────────────────────────
runsh "procesos XPNS"   "$PY - <<'PY'
import os
found = False
for d in sorted(os.listdir('/proc')):
    if not d.isdigit(): continue
    try:
        parts = open('/proc/%s/cmdline' % d,'rb').read().decode('utf8','replace').split(chr(0))
    except Exception: continue
    head = ' '.join(p for p in parts[:3] if p)
    full = ' '.join(p for p in parts if p)
    if any(k in head for k in ('expense_app_v2.py','run_termux.sh','cloudflared')):
        print(d, '|', full[:160]); found = True
print('(ninguno)' if not found else '')
PY"
runsh "dueno del puerto $PORT" "[ -f tools/port_utils.py ] && $PY tools/port_utils.py info $PORT || echo 'falta tools/port_utils.py (git pull)'"
runsh "puertos escuchando" "$PY - <<'PY'
for path in ('/proc/net/tcp','/proc/net/tcp6'):
    try: lines = open(path).read().splitlines()[1:]
    except Exception: continue
    for ln in lines:
        f = ln.split()
        if len(f) > 3 and f[3] == '0A':
            try: print('%-14s puerto %d' % (path, int(f[1].split(':')[1], 16)))
            except Exception: pass
PY"
runsh "health local"    "curl -s -m 10 http://127.0.0.1:$PORT/api/health || echo 'no responde'"

# ── 5. Cloudflare ────────────────────────────────────────────────────────────
runsh "cloudflared bin"  'command -v cloudflared && cloudflared --version 2>&1 | head -2 || echo "no esta en el PATH"'
runsh "cloudflared dir"  'ls -la "$HOME/.cloudflared" 2>/dev/null || echo "no existe ~/.cloudflared"'
# El config.yml se muestra CENSURANDO tokens/credenciales
runsh "cloudflared config (censurado)" '
for f in "$HOME/.cloudflared/config.yml" "$HOME/.cloudflared/config.yaml"; do
  [ -f "$f" ] || continue
  echo "--- $f ---"
  sed -E "s#(token|secret|password|AccountTag|TunnelSecret)([\"'"'"']?[[:space:]]*[:=][[:space:]]*).*#\1\2***CENSURADO***#I" "$f" \
  | sed -E "s#^([[:space:]]*tunnel[[:space:]]*:[[:space:]]*)(.{0,8}).*#\1\2...(id acortado)#I"
done
[ -f "$HOME/.cloudflared/config.yml" ] || [ -f "$HOME/.cloudflared/config.yaml" ] || echo "sin config.yml"'
runsh "cloudflared otros sitios" 'ls -la ./cloudflared* "$HOME"/cloudflared* "$PREFIX/bin/cloudflared" 2>/dev/null || echo "nada"'
runsh "servicio cloudflared" 'ls -la "$HOME/.termux/boot/" 2>/dev/null; crontab -l 2>/dev/null || echo "sin crontab"'

# ── 6. Logs ──────────────────────────────────────────────────────────────────
runsh "log xpns (ultimas 40)"        'tail -n 40 logs/xpns.log 2>/dev/null || echo "sin logs/xpns.log"'
runsh "log cloudflared (ultimas 30)" 'tail -n 30 logs/cloudflared.log 2>/dev/null || echo "sin logs/cloudflared.log"'

# ── 7. Bateria / wake lock ───────────────────────────────────────────────────
runsh "termux-api" 'command -v termux-wake-lock >/dev/null && echo "termux-api instalado" || echo "termux-api NO instalado"'
runsh "bateria"    'termux-battery-status 2>/dev/null || echo "(sin termux-api o sin permiso)"'

say ""
say "=================================================================="
say " LISTO. Todo quedo en:"
say "   $OUT"
say ""
say " Para verlo:      cat xpns_info.txt"
say " Tamano:          $(wc -c < "$OUT" 2>/dev/null) bytes"
say ""
say " Copia y pega el contenido completo de ese archivo."
say " (los tokens del tunel ya van censurados)"
say "=================================================================="
exit 0
