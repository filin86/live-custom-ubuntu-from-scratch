FROM python:3.13-slim

RUN apt-get update \
    && apt-get install -y --no-install-recommends rauc ca-certificates \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /srv/app
COPY requirements.txt /srv/app/requirements.txt
RUN pip install --no-cache-dir -r requirements.txt

COPY app /srv/app/app

ENV PYTHONUNBUFFERED=1 \
    INAUTO_UPDATE_DB=/var/lib/inauto-update/server.sqlite3 \
    INAUTO_BUNDLE_DIR=/var/lib/inauto-update/bundles

VOLUME ["/var/lib/inauto-update"]
EXPOSE 8000

CMD ["uvicorn", "app.main:app", "--host", "0.0.0.0", "--port", "8000"]
