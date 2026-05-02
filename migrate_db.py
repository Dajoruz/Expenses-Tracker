#!/usr/bin/env python3
"""
XPNS v3.1.0 — Database Migration Script
Aplica migraciones sin borrar la BD existente.

Uso:
    python migrate_db.py
"""

import sqlite3
import os
import sys

DB_PATH = os.path.join(os.path.dirname(os.path.abspath(__file__)), 'xpns_v3.db')


def column_exists(cursor, table, column):
    cursor.execute(f"PRAGMA table_info({table})")
    return any(row[1] == column for row in cursor.fetchall())


def table_exists(cursor, table):
    cursor.execute(
        "SELECT name FROM sqlite_master WHERE type='table' AND name=?",
        (table,)
    )
    return cursor.fetchone() is not None


def migrate():
    print("=" * 60)
    print("XPNS v3.1.0  -  Database Migration")
    print(f"DB: {DB_PATH}")
    print("=" * 60)

    if not os.path.exists(DB_PATH):
        print(f"\n[!] No se encontró la BD en {DB_PATH}")
        print("    Asegúrate de ejecutar primero la app para que se cree.")
        return False

    conn = sqlite3.connect(DB_PATH)
    cur = conn.cursor()

    try:
        # 1) Columna is_payed en expenses
        print("\n[1/3] expenses.is_payed ...", end=" ")
        if column_exists(cur, 'expenses', 'is_payed'):
            print("ya existe (skip)")
        else:
            cur.execute("ALTER TABLE expenses ADD COLUMN is_payed BOOLEAN DEFAULT 0")
            print("agregada")

        # 2) Columna expense_time en expenses
        print("[2/3] expenses.expense_time ...", end=" ")
        if column_exists(cur, 'expenses', 'expense_time'):
            print("ya existe (skip)")
        else:
            cur.execute(
                "ALTER TABLE expenses ADD COLUMN expense_time VARCHAR(8) DEFAULT '12:00:00'"
            )
            print("agregada")

        # 3) Tabla user_settings
        print("[3/3] tabla user_settings ...", end=" ")
        if table_exists(cur, 'user_settings'):
            print("ya existe (skip)")
        else:
            cur.execute("""
                CREATE TABLE user_settings (
                    id VARCHAR(36) PRIMARY KEY,
                    user_id VARCHAR(36) UNIQUE NOT NULL,
                    enable_description BOOLEAN DEFAULT 0,
                    enable_date_picker BOOLEAN DEFAULT 0,
                    created_at DATETIME DEFAULT CURRENT_TIMESTAMP,
                    updated_at DATETIME DEFAULT CURRENT_TIMESTAMP,
                    FOREIGN KEY (user_id) REFERENCES users(id) ON DELETE CASCADE
                )
            """)
            print("creada")

        conn.commit()

        # Verificación
        print("\n" + "-" * 60)
        print("Verificación final:")
        cur.execute("PRAGMA table_info(expenses)")
        cols = [row[1] for row in cur.fetchall()]
        print(f"  expenses cols: {len(cols)}  -> is_payed:{'OK' if 'is_payed' in cols else 'MISSING'}  expense_time:{'OK' if 'expense_time' in cols else 'MISSING'}")
        print(f"  user_settings: {'OK' if table_exists(cur, 'user_settings') else 'MISSING'}")

        print("\n[OK] Migración completada. Datos existentes intactos.")
        return True

    except Exception as e:
        conn.rollback()
        print(f"\n[ERROR] {type(e).__name__}: {e}")
        return False

    finally:
        cur.close()
        conn.close()


if __name__ == '__main__':
    sys.exit(0 if migrate() else 1)
