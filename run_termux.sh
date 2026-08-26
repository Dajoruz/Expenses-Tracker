#!/data/data/com.termux/files/usr/bin/bash
#
# Arranque de XPNS v3 en Termux.
#
# El motivo de este script: cuando apagas la pantalla, Android suspende los
# procesos de Termux y el servidor "se detiene solo". termux-wake-lock lo evita.
# Ademas relanza el server si se llegara a caer, para no quedarte sin la app.
#
#   chmod +x run_termux.sh
#   ./run_termux.sh
#
set -u

cd "$(dirname "$0")"

PORT="${XPNS_PORT:-5002}"
export XPNS_PORT="$PORT"

# 1. Wake lock: sin esto Android congela el proceso al bloquear el telefono.
if command -v termux-wake-lock >/dev/null 2>&1; then
  termux-wake-lock
  echo "[xpns] wake lock activado (el server sigue vivo con la pantalla apagada)"
else
  echo "[xpns] AVISO: termux-wake-lock no encontrado."
  echo "       Instalalo con:  pkg install termux-api"
  echo "       Sin el, Android detendra el server al apagar la pantalla."
fi

cleanup() {
  echo ""
  echo "[xpns] cerrando..."
  command -v termux-wake-unlock >/dev/null 2>&1 && termux-wake-unlock
  exit 0
}
trap cleanup INT TERM

# 2. Dependencias
python -c "import flask, flask_sqlalchemy, flask_cors" 2>/dev/null || {
  echo "[xpns] instalando dependencias..."
  pip install -r requirements.txt
}
python -c "import waitress" 2>/dev/null || {
  echo "[xpns] instalando waitress (servidor estable)..."
  pip install waitress
}

IP=$(ip route get 1 2>/dev/null | awk '{print $7; exit}')
echo "[xpns] local  : http://127.0.0.1:$PORT"
[ -n "${IP:-}" ] && echo "[xpns] en la red: http://$IP:$PORT"
echo "[xpns] Ctrl+C para detener"
echo ""

# 3. Relanzar si se cae
while true; do
  python expense_app_v2.py
  code=$?
  [ $code -eq 0 ] && break
  echo ""
  echo "[xpns] el server termino con codigo $code — reiniciando en 3s..."
  sleep 3
done

cleanup
