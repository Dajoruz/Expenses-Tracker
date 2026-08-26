XPNS (Provisional Name)

XPNS is a lightweight, web-based expense tracker designed for individuals and couples. This project was developed as a hobby to simplify personal finance tracking and shared spending transparency.
🚀 Features

    Simple Logging: Quickly record expenses with a name, amount, and category.

    Partner Sync: Link accounts with a partner to view shared/divided spending in real-time.

    Data Visualization: Interactive dashboards to monitor spending habits and trends.

    Data Portability: Export and download your recorded data for external use.

    Non-Profit: Created purely as a personal tool and learning exercise.

🛠️ Tech Stack

    Backend: Python with Flask

    Database: SQLite (Lightweight, serverless mapping)

    Frontend: HTML5, CSS3 (Custom UI)

📦 Installation & Setup

To run this project locally, ensure you have Python installed.

    Clone the repository:
    Bash

    git clone https://github.com/your-username/xpns.git
    cd xpns

    Set up a virtual environment:
    Bash

    python -m venv venv
    source venv/bin/activate  # On Windows: venv\Scripts\activate

    Install dependencies:
    (Make sure to create a requirements.txt if you haven't yet)
    Bash

    pip install flask

    Initialize the Database:
    The app uses SQLite, so the database will be created automatically upon the first run or via a provided schema script.

    Run the application:
    Bash

    python app.py

    Access the app at http://127.0.0.1:5000.

📈 Roadmap / Future Updates

    [ ] Implement a more robust "CVS" (Shared Expense) logic.

    [ ] Add more granular category filtering.

    [ ] Finalize the branding and move away from the "XPNS" placeholder.

📄 License

This project is for personal use and is not-for-profit. Feel free to fork it for your own personal hobby use.

---

## 📱 Correrlo en Termux (Android)

```bash
pkg install python termux-api
pip install -r requirements.txt
chmod +x run_termux.sh
./run_termux.sh
```

Abre `http://127.0.0.1:5002` en el navegador del telefono.

`run_termux.sh` se encarga de tres cosas que dan problemas en Android:

1. **`termux-wake-lock`** — sin el, Android congela el proceso al apagar la
   pantalla y el server "se detiene solo". Requiere `pkg install termux-api`.
2. **Levanta el server con `waitress`** en vez del servidor de desarrollo de
   Flask, que no aguanta horas en pie.
3. **Reinicia el proceso** si llegara a caerse.

### Variables de entorno

| Variable | Default | Para que sirve |
|---|---|---|
| `XPNS_PORT` | `5002` | Puerto de escucha |
| `XPNS_HOST` | `0.0.0.0` | Interfaz (usa `127.0.0.1` para no exponerlo en la red) |
| `XPNS_THREADS` | `4` | Hilos de waitress |
| `XPNS_HASH_METHOD` | `pbkdf2:sha256:120000` | Algoritmo de hash de contrasenas |

### Diagnostico

```bash
curl http://127.0.0.1:5002/api/health
```

Responde con el estado de la BD y el `journal_mode`, que debe decir `wal`:

```json
{"status":"healthy","db":"ok","journal_mode":"wal","users":2,
 "hash_method":"pbkdf2:sha256:120000"}
```

Si devuelve `"status":"degraded"`, el problema esta en SQLite y el detalle
viene en el campo `detail`.

### Nota sobre el primer login despues de actualizar

Las contrasenas se guardaban con **scrypt**, que en un telefono tarda segundos
y pide 32 MB de RAM por intento (esa era la causa de que el login se trabara).
Ahora se usa pbkdf2-sha256. **No hay que volver a registrarse**: la primera vez
que inicies sesion se valida tu hash viejo y se reescribe solo al formato nuevo.
Ese primer login sigue siendo lento una unica vez; los siguientes son instantaneos.

## 🌐 Cloudflare Tunnel (dajorus.com)

Los dos errores que ves significan cosas distintas:

| Error | Que pasa | Causa |
|---|---|---|
| **502 Bad Gateway** | El tunel vive, pero XPNS no responde detras | El server de Python se murio |
| **Error 1033** | Cloudflare no encuentra el tunel | `cloudflared` no esta corriendo |

`run_termux.sh` vigila **los dos** procesos cada 15 s y relanza el que se caiga,
que es lo que evita ambos errores.

El `~/.cloudflared/config.yml` debe apuntar al puerto local de XPNS:

```yaml
tunnel: <id-de-tu-tunel>
credentials-file: /data/data/com.termux/files/home/.cloudflared/<id>.json

ingress:
  - hostname: dajorus.com
    service: http://127.0.0.1:5002   # <-- debe coincidir con XPNS_PORT
  - service: http_status:404
```

### Lo que mas tumba esto en Android

La causa numero uno no es el codigo, es la **optimizacion de bateria**: Android
mata Termux en segundo plano y se caen el server y el tunel a la vez. Hay que
hacer las dos cosas:

1. Ajustes → Apps → Termux → Bateria → **Sin restricciones**.
2. `pkg install termux-api` para que `termux-wake-lock` funcione.

## 🩺 Diagnostico

```bash
./diagnose_termux.sh
```

Revisa dependencias, espacio en disco, si la BD se puede **escribir** (no solo
leer), integridad tras un apagon, cuantas copias del server hay, el estado de
`cloudflared` y el wake lock.

### "Veo los gastos viejos pero no puedo guardar nuevos"

Ese sintoma exacto significa que **SQLite puede leer pero no escribir**. Causas,
en orden de probabilidad:

1. **El `.db` esta en `/sdcard` o `~/storage/`.** SQLite no funciona bien en el
   almacenamiento compartido de Android: los bloqueos y el modo WAL fallan ahi.
   Tiene que estar en el almacenamiento interno de Termux (`~/projects/...`).
2. **No queda espacio.** Sin espacio libre SQLite no puede escribir su journal.
   Compruebalo con `df -h $HOME`.
3. **Dos copias del server** peleandose por la BD.
4. **Permisos** del archivo o de la carpeta que lo contiene.

La app ahora detecta esto al arrancar y lo dice en el log en vez de fallar en
silencio, y `/api/health` incluye `db_writable`.
