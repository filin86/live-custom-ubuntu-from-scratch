"""FastAPI update server для immutable panel firmware.

Endpoints:
  POST /api/upload      Загрузить .raucb (bearer auth).
  GET  /api/latest      Последняя версия в канале для compatible.
  POST /api/heartbeat   Панель сообщает о состоянии.
  GET  /bundles/<file>  Статическая выдача (в production через nginx).
  GET  /healthz         Лайвнес.
"""

from __future__ import annotations

import hashlib
import os
import re
import subprocess
from datetime import datetime, timezone
from pathlib import Path

from fastapi import FastAPI, File, Form, Header, HTTPException, UploadFile, status
from pydantic import BaseModel, Field
from fastapi.responses import FileResponse, JSONResponse

from . import db

BUNDLE_DIR = Path(os.environ.get("INAUTO_BUNDLE_DIR", "/var/lib/inauto-update/bundles"))
UPLOAD_TOKEN = os.environ.get("INAUTO_UPLOAD_TOKEN", "")
RAUC_KEYRING = os.environ.get("INAUTO_RAUC_KEYRING", "")
PUBLIC_BASE_URL = os.environ.get("INAUTO_PUBLIC_BASE_URL", "").rstrip("/")

PROD_VERSION_RE = re.compile(r"^[0-9]{4}\.[0-9]{2}\.[0-9]{2}\.[0-9]+$")
COMPATIBLE_RE = re.compile(r"^inauto-panel-[a-z0-9]+-[a-z0-9]+-[a-z0-9.\-]+-v[0-9]+$")

app = FastAPI(title="Inauto panel update server", version="1.0")


@app.on_event("startup")
def _startup() -> None:
    if not UPLOAD_TOKEN:
        raise RuntimeError("INAUTO_UPLOAD_TOKEN обязателен; отказ стартовать без bearer token'а")
    if not RAUC_KEYRING or not Path(RAUC_KEYRING).is_file():
        raise RuntimeError(
            f"INAUTO_RAUC_KEYRING обязателен и должен указывать на PEM keyring (got '{RAUC_KEYRING}'); "
            "без него upload не сможет verify bundle подпись"
        )
    if not PUBLIC_BASE_URL:
        raise RuntimeError(
            "INAUTO_PUBLIC_BASE_URL обязателен; панели скачивают bundle по абсолютному URL из /api/latest, "
            "а не по относительному пути"
        )
    BUNDLE_DIR.mkdir(parents=True, exist_ok=True)
    db.init_db()


def _require_token(auth_header: str | None) -> None:
    expected = f"Bearer {UPLOAD_TOKEN}"
    if auth_header != expected:
        raise HTTPException(status.HTTP_401_UNAUTHORIZED, "invalid token")


def _extract_bundle_metadata(bundle_path: Path) -> tuple[str, str]:
    """Читает compatible+version из manifest'а через verified `rauc info`.

    RAUC_KEYRING обязателен (проверено в _startup), поэтому никаких
    optional fallback'ов здесь нет — bundle без валидной подписи
    отвергается до записи в базу.
    """
    cmd = [
        "rauc", "info",
        "--keyring", RAUC_KEYRING,
        "--output-format=shell",
        str(bundle_path),
    ]
    try:
        proc = subprocess.run(cmd, capture_output=True, text=True, timeout=30, check=True)
    except subprocess.CalledProcessError as e:
        raise HTTPException(status.HTTP_400_BAD_REQUEST, f"rauc info failed: {e.stderr}") from e
    compatible = version = ""
    for line in proc.stdout.splitlines():
        if line.startswith("RAUC_MF_COMPATIBLE="):
            compatible = line.split("=", 1)[1].strip().strip("'\"")
        elif line.startswith("RAUC_MF_VERSION="):
            version = line.split("=", 1)[1].strip().strip("'\"")
    if not compatible or not version:
        raise HTTPException(status.HTTP_400_BAD_REQUEST, "manifest без compatible/version")
    return compatible, version


@app.post("/api/upload")
async def upload_bundle(
    file: UploadFile = File(...),
    channel: str = Form(...),
    authorization: str | None = Header(default=None),
) -> JSONResponse:
    _require_token(authorization)
    if channel not in ("candidate", "stable"):
        raise HTTPException(status.HTTP_400_BAD_REQUEST, "channel должен быть candidate или stable")
    if not file.filename or not file.filename.endswith(".raucb"):
        raise HTTPException(status.HTTP_400_BAD_REQUEST, "ожидается .raucb файл")

    dest = BUNDLE_DIR / Path(file.filename).name
    if dest.exists():
        raise HTTPException(status.HTTP_409_CONFLICT, f"{dest.name} уже загружен")

    # Всё, что ниже, идёт под единым try — любое исключение после того,
    # как dest создан, должно удалить недописанный / неверифицированный
    # файл. Без этого мы бы копили битые bundle'ы в BUNDLE_DIR.
    hasher = hashlib.sha256()
    try:
        with dest.open("wb") as f:
            while chunk := await file.read(1 << 20):
                hasher.update(chunk)
                f.write(chunk)

        compatible, version = _extract_bundle_metadata(dest)
        if not COMPATIBLE_RE.match(compatible):
            raise HTTPException(
                status.HTTP_400_BAD_REQUEST,
                f"compatible '{compatible}' не проходит regex",
            )
        if not PROD_VERSION_RE.match(version):
            raise HTTPException(
                status.HTTP_400_BAD_REQUEST,
                f"version '{version}' не в production-формате YYYY.MM.DD.N",
            )

        with db.connect() as conn:
            try:
                conn.execute(
                    """
                    INSERT INTO bundles(filename, compatible, version, channel, sha256)
                    VALUES (?, ?, ?, ?, ?)
                    """,
                    (dest.name, compatible, version, channel, hasher.hexdigest()),
                )
            except Exception as e:
                raise HTTPException(status.HTTP_409_CONFLICT, f"duplicate: {e}") from e
    except Exception:
        dest.unlink(missing_ok=True)
        raise

    return JSONResponse(
        {
            "filename": dest.name,
            "compatible": compatible,
            "version": version,
            "channel": channel,
            "sha256": hasher.hexdigest(),
        }
    )


def _version_key(v: str) -> tuple[int, ...]:
    return tuple(int(p) for p in v.split("."))


@app.get("/api/latest")
def api_latest(
    channel: str,
    compatible: str,
    x_panel_serial: str | None = Header(default=None),
) -> JSONResponse:
    if channel not in ("candidate", "stable"):
        raise HTTPException(status.HTTP_400_BAD_REQUEST, "invalid channel")
    with db.connect() as conn:
        rows = conn.execute(
            "SELECT filename, version FROM bundles WHERE channel=? AND compatible=?",
            (channel, compatible),
        ).fetchall()
    if not rows:
        return JSONResponse({})
    latest = max(rows, key=lambda r: _version_key(r["version"]))
    # PUBLIC_BASE_URL обязателен (проверено в _startup), никогда не пустой.
    url = f"{PUBLIC_BASE_URL}/bundles/{latest['filename']}"
    return JSONResponse(
        {"version": latest["version"], "url": url, "force_downgrade": False}
    )


class Heartbeat(BaseModel):
    compatible: str
    version: str
    serial: str | None = None
    slot: str | None = None
    last_error: str | None = None


@app.post("/api/heartbeat")
def api_heartbeat(body: Heartbeat, x_panel_serial: str | None = Header(default=None)) -> JSONResponse:
    serial = body.serial or x_panel_serial
    if not serial:
        raise HTTPException(status.HTTP_400_BAD_REQUEST, "serial обязателен (body.serial или X-Panel-Serial)")
    if not body.slot and not body.last_error:
        raise HTTPException(
            status.HTTP_400_BAD_REQUEST,
            "если slot пустой, last_error обязателен",
        )

    now = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    with db.connect() as conn:
        conn.execute(
            """
            INSERT INTO panels(serial, compatible, last_seen, current_version, current_slot, last_error)
            VALUES (?, ?, ?, ?, ?, ?)
            ON CONFLICT(serial) DO UPDATE SET
                compatible=excluded.compatible,
                last_seen=excluded.last_seen,
                current_version=excluded.current_version,
                current_slot=excluded.current_slot,
                last_error=excluded.last_error
            """,
            (serial, body.compatible, now, body.version, body.slot, body.last_error),
        )
    return JSONResponse({"ok": True})


@app.get("/bundles/{filename}")
def serve_bundle(filename: str) -> FileResponse:
    # В production отдаёт nginx. Этот endpoint — fallback для dev.
    if ".." in filename or "/" in filename:
        raise HTTPException(status.HTTP_400_BAD_REQUEST)
    path = BUNDLE_DIR / filename
    if not path.is_file():
        raise HTTPException(status.HTTP_404_NOT_FOUND)
    return FileResponse(path, media_type="application/octet-stream")


@app.get("/healthz")
def healthz() -> dict[str, str]:
    return {"status": "ok"}
