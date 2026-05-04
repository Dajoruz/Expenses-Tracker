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


def add_column_safe(cur, table, column, ddl):
    """ALTER TABLE ... ADD COLUMN ... idempotente."""
    if column_exists(cur, table, column):
        print(f"  - {table}.{column}: ya existe (skip)")
        return False
    cur.execute(f"ALTER TABLE {table} ADD COLUMN {column} {ddl}")
    print(f"  + {table}.{column}: agregada")
    return True


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
        # ── 1. expenses: nuevas columnas ────────────────────────────────────
        print("\n[1] Tabla expenses (columnas nuevas):")
        add_column_safe(cur, 'expenses', 'is_payed',     "BOOLEAN DEFAULT 0")
        add_column_safe(cur, 'expenses', 'expense_time', "VARCHAR(8) DEFAULT '12:00:00'")

        # ── 2. user_settings: tabla + columnas ──────────────────────────────
        print("\n[2] Tabla user_settings:")
        if table_exists(cur, 'user_settings'):
            print("  - user_settings: ya existe")
        else:
            cur.execute("""
                CREATE TABLE user_settings (
                    id VARCHAR(36) PRIMARY KEY,
                    user_id VARCHAR(36) UNIQUE NOT NULL,
                    enable_description BOOLEAN DEFAULT 0,
                    enable_date_picker BOOLEAN DEFAULT 0,
                    enable_wishlist    BOOLEAN DEFAULT 0,
                    created_at DATETIME DEFAULT CURRENT_TIMESTAMP,
                    updated_at DATETIME DEFAULT CURRENT_TIMESTAMP,
                    FOREIGN KEY (user_id) REFERENCES users(id) ON DELETE CASCADE
                )
            """)
            print("  + user_settings: creada")

        # Agregar columna nueva si la tabla ya existía
        add_column_safe(cur, 'user_settings', 'enable_wishlist', "BOOLEAN DEFAULT 0")

        # ── 3. wishlist: tabla nueva ────────────────────────────────────────
        print("\n[3] Tabla wishlist:")
        if table_exists(cur, 'wishlist'):
            print("  - wishlist: ya existe")
        else:
            cur.execute("""
                CREATE TABLE wishlist (
                    id VARCHAR(36) PRIMARY KEY,
                    user_id VARCHAR(36) NOT NULL,
                    couple_username VARCHAR(50),
                    name VARCHAR(120) NOT NULL,
                    description VARCHAR(500),
                    image_data BLOB,
                    image_mime VARCHAR(40),
                    image_size INTEGER,
                    created_at DATETIME DEFAULT CURRENT_TIMESTAMP,
                    is_deleted BOOLEAN DEFAULT 0,
                    FOREIGN KEY (user_id) REFERENCES users(id) ON DELETE CASCADE
                )
            """)
            cur.execute("CREATE INDEX idx_wishlist_user ON wishlist(user_id, is_deleted)")
            cur.execute("CREATE INDEX idx_wishlist_couple ON wishlist(couple_username, is_deleted)")
            print("  + wishlist: creada")
            print("  + indices wishlist: creados")

        conn.commit()

        # ── Verificación final ──────────────────────────────────────────────
        print("\n" + "-" * 60)
        print("Verificación final:")
        cur.execute("PRAGMA table_info(expenses)")
        cols = [row[1] for row in cur.fetchall()]
        print(f"  expenses ({len(cols)} cols): is_payed={'OK' if 'is_payed' in cols else 'MISSING'}, expense_time={'OK' if 'expense_time' in cols else 'MISSING'}")

        cur.execute("PRAGMA table_info(user_settings)")
        ucols = [row[1] for row in cur.fetchall()]
        print(f"  user_settings ({len(ucols)} cols): enable_wishlist={'OK' if 'enable_wishlist' in ucols else 'MISSING'}")

        print(f"  wishlist: {'OK' if table_exists(cur, 'wishlist') else 'MISSING'}")

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
