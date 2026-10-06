# syntax=docker/dockerfile:1
# FastAPI backend for the Raspberry Pi (linux/arm64). Built by deploy/build.sh; context = repo root.

FROM python:3.13-slim AS build
ENV PIP_NO_CACHE_DIR=1 PIP_DISABLE_PIP_VERSION_CHECK=1
RUN python -m venv /venv
COPY requirements.txt .
RUN /venv/bin/pip install -r requirements.txt


FROM python:3.13-slim
# HACKYEAH_ENV_FILE="": settings come only from the environment (compose env_file), never from a baked-in .env.
ENV PATH=/venv/bin:$PATH \
    PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    HACKYEAH_ENV_FILE=""
RUN useradd --system --uid 10001 --home-dir /app app
WORKDIR /app
COPY --from=build /venv /venv
COPY app ./app
# Local photo storage (STORAGE_BACKEND=local / no Cloudinary); a volume in compose.
RUN mkdir media && chown app:app media
USER app

EXPOSE 8000
HEALTHCHECK --interval=30s --timeout=5s --start-period=30s --retries=3 \
    CMD ["python", "-c", "import urllib.request; urllib.request.urlopen('http://127.0.0.1:8000/health', timeout=4)"]
# Behind the Cloudflare tunnel: trust X-Forwarded-* so redirects and URLs use https and the public host.
CMD ["uvicorn", "app.main:app", "--host", "0.0.0.0", "--port", "8000", "--proxy-headers", "--forwarded-allow-ips", "*"]
