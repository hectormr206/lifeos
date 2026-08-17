# The blind relay. Small on purpose: it holds other people's secrets in a form
# it cannot read, and the best defence for that is being auditable in one
# sitting.
FROM python:3.12-slim

# uv for a reproducible install from the lockfile — the same reason axi uses
# it. A relay built from floating versions is a relay whose crypto library
# changed without anyone deciding to change it.
COPY --from=ghcr.io/astral-sh/uv:0.12.5 /uv /usr/local/bin/uv

WORKDIR /srv/relay

COPY pyproject.toml uv.lock ./
RUN uv sync --frozen --no-dev --no-install-project

COPY app ./app

# Non-root: the process needs to write exactly one file, in one mounted volume.
RUN useradd --system --uid 10001 relay && mkdir -p /data && chown relay /data
USER relay

ENV PATH="/srv/relay/.venv/bin:$PATH" \
    RELAY_DB_PATH=/data/relay.db

EXPOSE 8080
HEALTHCHECK --interval=30s --timeout=5s --start-period=5s \
    CMD python -c "import urllib.request;urllib.request.urlopen('http://127.0.0.1:8080/healthz')"

CMD ["uvicorn", "app.server:app", "--host", "0.0.0.0", "--port", "8080"]
