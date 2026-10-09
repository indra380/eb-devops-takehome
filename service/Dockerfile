FROM python:3.12.11-slim-bookworm AS builder

WORKDIR /build
COPY app.py .
# Ship bytecode only so the runtime stage does not need the source tree.
RUN python -m compileall -b -q app.py && rm app.py

FROM python:3.12.11-slim-bookworm

RUN apt-get update \
    && apt-get upgrade -y --no-install-recommends \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/* \
    && groupadd --system --gid 10001 app \
    && useradd --system --uid 10001 --gid 10001 --home-dir /app --shell /usr/sbin/nologin app

WORKDIR /app
COPY --from=builder --chown=10001:10001 /build/app.pyc /app/app.pyc

USER 10001:10001

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    PORT=8080

EXPOSE 8080

CMD ["python", "/app/app.pyc"]
