# ── StockPulse Backend ────────────────────────────────────────────────────────
# Multi-stage build: keeps the final image lean by separating dependency
# installation from the runtime image.
# ─────────────────────────────────────────────────────────────────────────────

# ── Stage 1: dependency builder ───────────────────────────────────────────────
FROM python:3.13-slim AS builder

WORKDIR /build

# Install build tools required by some packages (pandas, etc.)
RUN apt-get update && apt-get install -y --no-install-recommends \
        build-essential \
    && rm -rf /var/lib/apt/lists/*

COPY requirements.txt .
RUN pip install --no-cache-dir --prefix=/install -r requirements.txt


# ── Stage 2: runtime image ────────────────────────────────────────────────────
FROM python:3.13-slim AS runtime

WORKDIR /app

# Copy installed packages from builder stage
COPY --from=builder /install /usr/local

# Copy only the application source (no venv, no .env, no test artifacts)
COPY *.py ./

# Persistent data directory — mount a Railway Volume here to survive restarts
RUN mkdir -p /app/data

# ── Environment defaults (all overridden by Railway env vars) ─────────────────
ENV DATA_DIR=/app/data \
    HOST=0.0.0.0 \
    PORT=8000 \
    ENV=production \
    LOG_LEVEL=info \
    PYTHONUNBUFFERED=1 \
    PYTHONDONTWRITEBYTECODE=1

EXPOSE 8000

# Healthcheck — Railway uses this to decide when the container is ready
HEALTHCHECK --interval=30s --timeout=10s --start-period=60s --retries=3 \
    CMD python -c "import urllib.request; urllib.request.urlopen('http://localhost:8000/health')"

CMD ["python", "main.py"]
