"""SQLite helpers для update server.

Таблицы:
- bundles:  загруженные .raucb, ключ по compatible+version+channel.
- panels:   реестр известных панелей, last_seen/current_version/current_slot.
"""

from __future__ import annotations

import os
import sqlite3
from contextlib import contextmanager
from collections.abc import Iterator

DB_PATH = os.environ.get("INAUTO_UPDATE_DB", "/var/lib/inauto-update/server.sqlite3")

SCHEMA = """
CREATE TABLE IF NOT EXISTS bundles (
    id           INTEGER PRIMARY KEY AUTOINCREMENT,
    filename     TEXT NOT NULL,
    compatible   TEXT NOT NULL,
    version      TEXT NOT NULL,
    channel      TEXT NOT NULL CHECK(channel IN ('candidate', 'stable')),
    sha256       TEXT NOT NULL,
    uploaded_at  TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now')),
    UNIQUE(compatible, version, channel)
);

CREATE INDEX IF NOT EXISTS idx_bundles_channel_compatible
    ON bundles(channel, compatible);

CREATE TABLE IF NOT EXISTS panels (
    serial            TEXT PRIMARY KEY,
    compatible        TEXT,
    channel           TEXT,
    last_seen         TEXT,
    current_version   TEXT,
    current_slot      TEXT,
    last_error        TEXT
);
"""


def init_db() -> None:
    os.makedirs(os.path.dirname(DB_PATH), exist_ok=True)
    with connect() as conn:
        conn.executescript(SCHEMA)


@contextmanager
def connect() -> Iterator[sqlite3.Connection]:
    conn = sqlite3.connect(DB_PATH, isolation_level=None)
    conn.row_factory = sqlite3.Row
    conn.execute("PRAGMA journal_mode=WAL")
    conn.execute("PRAGMA foreign_keys=ON")
    try:
        yield conn
    finally:
        conn.close()
