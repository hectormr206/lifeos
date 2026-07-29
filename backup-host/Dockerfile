# Stdlib-only service: the base image needs a Python interpreter and nothing
# else. No pip install runs here, so there is no dependency that can break a
# rebuild months from now, and nothing to patch beyond the base image itself.
FROM python:3.12-alpine

# Run as an unprivileged user. The volume is chowned to the same uid by the
# compose file, so the container never needs write access to anything else.
RUN adduser -D -u 10001 lifeos

WORKDIR /app
COPY server.py /app/server.py

USER lifeos

ENV LIFEOS_BACKUP_ROOT=/data \
    LIFEOS_BACKUP_HOST=0.0.0.0 \
    LIFEOS_BACKUP_PORT=8099

EXPOSE 8099
VOLUME ["/data"]

# Health probes the unauthenticated endpoint, so the orchestrator never needs
# a copy of the access key to know whether the service is alive.
HEALTHCHECK --interval=30s --timeout=5s --start-period=5s --retries=3 \
    CMD python3 -c "import urllib.request,sys; sys.exit(0 if urllib.request.urlopen('http://127.0.0.1:8099/v1/health', timeout=4).status==200 else 1)"

ENTRYPOINT ["python3", "/app/server.py"]
