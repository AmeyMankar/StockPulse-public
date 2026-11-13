"""
main.py
-------
FastAPI server for StockPulse backend.
- Exposes REST API consumed by the iOS app
- Runs a background APScheduler job every 15 minutes
- Persists last scan and device tokens to JSON files (DATA_DIR)
- API key auth on mutating/sensitive endpoints
"""

import os
import json
import logging
import asyncio
import math
from datetime import datetime
from contextlib import asynccontextmanager
from pathlib import Path

import httpx
import sentry_sdk
from sentry_sdk.integrations.fastapi import FastApiIntegration
from sentry_sdk.integrations.asyncio import AsyncioIntegration
from fastapi import FastAPI, HTTPException, BackgroundTasks, Depends, Request
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import Response, JSONResponse
from fastapi.security import APIKeyHeader
from pydantic import BaseModel
from dotenv import load_dotenv
from apscheduler.schedulers.asyncio import AsyncIOScheduler

from reddit_scraper import RedditScraper
from ai_analyzer import AIAnalyzer, TickerAnalysis
from push_notifications import APNsPusher

load_dotenv(override=True)
logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(name)s — %(message)s")
logger = logging.getLogger("stockpulse")

# ── Error Reporting (Sentry) ──────────────────────────────────────────────────
_SENTRY_DSN = os.getenv("SENTRY_DSN", "")
_ENV = os.getenv("ENV", "development")


def _init_sentry() -> None:
    """Initialise Sentry if SENTRY_DSN is set; graceful no-op otherwise."""
    if not _SENTRY_DSN:
        logger.info("SENTRY_DSN not set — crash reporting disabled (add to .env for production)")
        return
    sentry_sdk.init(
        dsn=_SENTRY_DSN,
        integrations=[FastApiIntegration(), AsyncioIntegration()],
        environment=_ENV,
        release="stockpulse@1.0.0",
        traces_sample_rate=0.1,   # 10 % of requests for performance monitoring
        send_default_pii=False,   # never send personal data to Sentry
    )
    logger.info("Sentry error reporting active (env=%s)", _ENV)


def _capture(exc: Exception) -> None:
    """Send an exception to Sentry (if configured)."""
    if _SENTRY_DSN:
        sentry_sdk.capture_exception(exc)


# ── Startup Validation ────────────────────────────────────────────────────────

def validate_env() -> None:
    """
    Fail fast if required env vars are absent.
    Called before the server starts accepting requests.
    """
    required = ["ANTHROPIC_API_KEY"]
    missing = [k for k in required if not os.getenv(k)]
    if missing:
        logger.critical(
            "Cannot start — missing required env vars: %s  "
            "(check your .env file)",
            ", ".join(missing),
        )
        raise SystemExit(1)


# ── Config ────────────────────────────────────────────────────────────────────
DATA_DIR = Path(os.getenv("DATA_DIR", ".").strip())
SCAN_CACHE_FILE = DATA_DIR / "last_scan.json"
DEVICES_FILE = DATA_DIR / "devices.json"
SETTINGS_FILE = DATA_DIR / "settings.json"
WATCHLIST_FILE = DATA_DIR / "watchlists.json"
# Two separate keys so a leak of the app-embedded key can't be used to forge
# scan data via /scan/ingest or hit admin-only endpoints (see require_ingest_key).
_CLIENT_API_KEY = os.getenv("CLIENT_API_KEY", "")   # used by the iOS app
_INGEST_API_KEY = os.getenv("INGEST_API_KEY", "")   # used only by scan_worker.py

ALLOWED_INTERVALS = {900, 1800, 3600, 21600, 86400}
_default_interval = int(os.getenv("SCAN_INTERVAL_SECONDS", 900))
SCAN_INTERVAL = _default_interval

# ── Globals ───────────────────────────────────────────────────────────────────
scraper: RedditScraper | None = None
analyzer: AIAnalyzer | None = None
pusher: APNsPusher | None = None

last_scan: dict = {
    "timestamp": None,
    "results": [],
    "raw_ticker_count": 0,
}

# Pre-serialised response bytes — updated atomically each time last_scan changes.
# Serving raw bytes bypasses per-request JSON encoding, cutting CPU at high concurrency.
_scan_json_bytes: bytes = b"{}"

registered_devices: set[str] = set()
watchlist_store: dict[str, list[str]] = {}   # device_token → [TICKER, ...]
prev_scan_tickers: set[str] = set()           # tracks which tickers were in the last scan
# Tracks the last scan_id (started_at ISO string) for which each
# (device_token, ticker) pair was notified — prevents duplicate alerts
# within the same scan or across rapid redeployments.
_last_notified: dict[tuple[str, str], str] = {}

scheduler = AsyncIOScheduler()


def _update_scan_cache(data: dict) -> None:
    """Update last_scan and pre-serialise to bytes in one place."""
    global last_scan, _scan_json_bytes
    last_scan = data
    try:
        _scan_json_bytes = json.dumps(data, separators=(",", ":"), allow_nan=False).encode()
    except (ValueError, TypeError) as e:
        # Data contains NaN/Infinity — serve previous bytes unchanged to avoid
        # sending invalid JSON to the iOS app (which would cause a decode error).
        logger.error("Scan cache contains non-finite float values — keeping previous bytes: %s", e)


# HTTP Cache-Control header value for read endpoints (data changes at most hourly)
_CACHE_HEADER = "public, max-age=30, stale-while-revalidate=60"


# ── Persistence ───────────────────────────────────────────────────────────────
def _load_scan_cache() -> dict:
    try:
        if SCAN_CACHE_FILE.exists():
            return json.loads(SCAN_CACHE_FILE.read_text())
    except Exception as e:
        logger.warning(f"Could not load scan cache: {e}")
    return {"timestamp": None, "results": [], "raw_ticker_count": 0}


def _save_scan_cache(data: dict):
    try:
        SCAN_CACHE_FILE.write_text(json.dumps(data))
    except Exception as e:
        logger.warning(f"Could not save scan cache: {e}")


def _load_settings() -> dict:
    try:
        if SETTINGS_FILE.exists():
            return json.loads(SETTINGS_FILE.read_text())
    except Exception as e:
        logger.warning(f"Could not load settings: {e}")
    return {}


def _save_settings(data: dict):
    try:
        SETTINGS_FILE.write_text(json.dumps(data))
    except Exception as e:
        logger.warning(f"Could not save settings: {e}")


def _load_devices() -> set[str]:
    try:
        if DEVICES_FILE.exists():
            return set(json.loads(DEVICES_FILE.read_text()))
    except Exception as e:
        logger.warning(f"Could not load devices: {e}")
    return set()


def _save_devices(devices: set[str]):
    try:
        DEVICES_FILE.write_text(json.dumps(list(devices)))
    except Exception as e:
        logger.warning(f"Could not save devices: {e}")


def _load_watchlists() -> dict[str, list[str]]:
    try:
        if WATCHLIST_FILE.exists():
            return json.loads(WATCHLIST_FILE.read_text())
    except Exception as e:
        logger.warning(f"Could not load watchlists: {e}")
    return {}


def _save_watchlists(data: dict[str, list[str]]):
    try:
        WATCHLIST_FILE.write_text(json.dumps(data))
    except Exception as e:
        logger.warning(f"Could not save watchlists: {e}")


# ── Auth ──────────────────────────────────────────────────────────────────────
_api_key_header = APIKeyHeader(name="X-API-Key", auto_error=False)


async def require_client_key(key: str | None = Depends(_api_key_header)):  # noqa: B008
    """Dependency: validates X-API-Key header for app-facing endpoints.
    Disabled when CLIENT_API_KEY env var is unset."""
    if not _CLIENT_API_KEY:
        return  # auth disabled — useful for local dev
    if key != _CLIENT_API_KEY:
        raise HTTPException(status_code=401, detail="Invalid or missing API key")


async def require_ingest_key(key: str | None = Depends(_api_key_header)):  # noqa: B008
    """Dependency: validates X-API-Key header for worker/admin-only endpoints
    (/scan/ingest, /scan/interval, device deletion). Never shipped in the app.
    Disabled when INGEST_API_KEY env var is unset."""
    if not _INGEST_API_KEY:
        return  # auth disabled — useful for local dev
    if key != _INGEST_API_KEY:
        raise HTTPException(status_code=401, detail="Invalid or missing API key")


# ── Helpers ───────────────────────────────────────────────────────────────────
def analysis_to_dict(a: TickerAnalysis) -> dict:
    return {
        "ticker": a.ticker,
        "companyName": a.company_name,
        "currentPrice": a.current_price,
        "priceChangePct": a.price_change_pct,
        "weekChangePct": a.week_change_pct,
        "volumeVsAvg": a.volume_vs_avg,
        "marketCap": a.market_cap,
        "totalMentions": a.total_mentions,
        "subredditBreakdown": a.subreddit_breakdown,
        "avgSentimentRaw": a.avg_sentiment_raw,
        "bullishCount": a.bullish_count,
        "bearishCount": a.bearish_count,
        "neutralCount": a.neutral_count,
        # topPosts kept as [String] for backward compat with older app builds
        "topPosts": [p.get("title", "") for p in a.top_posts] if a.top_posts else [],
        # redditPosts carries full objects {title, url, score} for the new build
        "redditPosts": a.top_posts,
        "investmentScore": a.investment_score,
        "sentimentScore": a.sentiment_score,
        "sentimentLabel": a.sentiment_label,
        "riskLevel": a.risk_level,
        "analystSummary": a.analyst_summary,
        "catalysts": a.catalysts,
        "redFlag": a.red_flag,
        "negativeTraction": a.negative_traction,
        "recommendation": a.recommendation,
    }


async def run_scan(attempt: int = 0) -> None:
    """
    Core scan job: scrape → analyze → push → persist.

    On failure, retries once after a 60-second back-off.
    Exceptions are captured by Sentry (if configured).
    Expired APNs tokens are automatically pruned from storage.
    """
    global registered_devices, prev_scan_tickers, _last_notified
    _MAX_ATTEMPTS = 2

    # Defer to mac_worker if its data is still fresh.
    # MAC_WORKER_INTERVAL_SECONDS controls how often the Mac cron runs (default 5h).
    # Threshold = interval × 1.2 so Railway only kicks in well after a missed Mac scan.
    # To change Mac cron to 15 min: set MAC_WORKER_INTERVAL_SECONDS=900 in Railway
    # Variables → threshold becomes ~18 min automatically.
    _mac_interval = int(os.getenv("MAC_WORKER_INTERVAL_SECONDS", str(5 * 3600)))
    _mac_threshold = _mac_interval * 1.2
    if last_scan.get("source") == "mac_worker" and last_scan.get("ingested_at"):
        try:
            ingested_at = datetime.fromisoformat(last_scan["ingested_at"].replace("Z", "+00:00"))
            age = (datetime.now(ingested_at.tzinfo) - ingested_at).total_seconds()
            if age < _mac_threshold:
                logger.info(
                    "Skipping Reddit-only scan — mac_worker data is %.0fm old (threshold %.0fm)",
                    age / 60, _mac_threshold / 60,
                )
                return
        except Exception:
            pass

    logger.info("=== Starting Reddit scan (attempt %d/%d) ===", attempt + 1, _MAX_ATTEMPTS)

    try:
        loop = asyncio.get_event_loop()
        top_tickers = await loop.run_in_executor(
            None, lambda: scraper.get_top_tickers(n=40, min_mentions=2)
        )
        logger.info("Scraped %d qualifying tickers", len(top_tickers))

        analyses = await loop.run_in_executor(
            None, lambda: analyzer.analyze(top_tickers[:25])
        )
        logger.info("Analysis complete: %d results", len(analyses))

        if analyses:
            scan_id = datetime.utcnow().isoformat() + "Z"
            _update_scan_cache({
                "timestamp": scan_id,
                "results": [analysis_to_dict(a) for a in analyses],
                "raw_ticker_count": len(top_tickers),
                "window_seconds": SCAN_INTERVAL,
            })
            _save_scan_cache(last_scan)

            if pusher and registered_devices:
                # Send scan alerts to all devices concurrently (capped at 50 simultaneous)
                push_results = await pusher.send_to_all_async(list(registered_devices), analyses)
                expired = {tok for tok, result in push_results.items() if result == "expired"}
                if expired:
                    registered_devices -= expired  # noqa: F823
                    _save_devices(registered_devices)
                    logger.info("Pruned %d expired APNs tokens", len(expired))
                ok_count = sum(1 for r in push_results.values() if r == "ok")
                logger.info(
                    "Push complete: %d ok, %d expired, %d error",
                    ok_count,
                    len(expired),
                    sum(1 for r in push_results.values() if r == "error"),
                )

            # ── Watchlist notifications (concurrent) ──────────────────────
            # Notify once per scan per (device, ticker) pair — scan_id deduplicates
            # across rapid redeployments or retries within the same scan window.
            current_ticker_set = {a.ticker for a in analyses}
            if pusher and watchlist_store:
                # Build list of (device_token, ticker, analysis) tuples to notify
                pending: list[tuple[str, str, str | None, int | None]] = []
                for device_token, watched in watchlist_store.items():
                    for sym in set(watched) & current_ticker_set:
                        if _last_notified.get((device_token, sym)) == scan_id:
                            continue
                        analysis = next((a for a in analyses if a.ticker == sym), None)
                        if not analysis:
                            continue
                        post_title = analysis.top_posts[0]["title"] if analysis.top_posts else None
                        pending.append((device_token, sym, post_title, analysis.investment_score))

                if pending:
                    semaphore = asyncio.Semaphore(50)
                    async with httpx.AsyncClient(http2=True) as client:
                        tasks = [
                            pusher.send_watchlist_alert_async(
                                client, semaphore, token, sym, post_title, score
                            )
                            for token, sym, post_title, score in pending
                        ]
                        wl_results = await asyncio.gather(*tasks, return_exceptions=True)

                    expired_watchlist: set[str] = set()
                    for (token, sym, _, _), outcome in zip(pending, wl_results):
                        # send_watchlist_alert_async returns (device_token, result_str)
                        _, result = outcome if isinstance(outcome, tuple) else (None, "error")
                        logger.info("Watchlist alert %s → %s...: %s", sym, token[:12], result)
                        if result != "error":
                            _last_notified[(token, sym)] = scan_id
                        if result == "expired":
                            expired_watchlist.add(token)

                    if expired_watchlist:
                        registered_devices -= expired_watchlist
                        _save_devices(registered_devices)
            prev_scan_tickers = current_ticker_set
        else:
            logger.warning("Scan returned 0 results — retaining previous scan data")

    except Exception as e:
        logger.exception("Scan failed (attempt %d/%d): %s", attempt + 1, _MAX_ATTEMPTS, e)
        _capture(e)
        if attempt < _MAX_ATTEMPTS - 1:
            delay = 60 * (attempt + 1)   # 60 s on first retry
            logger.info("Retrying scan in %ds...", delay)
            await asyncio.sleep(delay)
            await run_scan(attempt=attempt + 1)


# ── APNs Key Resolution ───────────────────────────────────────────────────────

def _resolve_apns_key() -> str | None:
    """
    Resolve the APNs private key path for use at runtime.

    Supports two sources (checked in order):
      1. APNS_KEY_CONTENT — base64-encoded .p8 file content.
         Use this for cloud deployments (Railway, Heroku, etc.) where you
         can't commit or mount a key file.  Set it with:
             export APNS_KEY_CONTENT=$(base64 -i AuthKey_XXXXXXXX.p8)
      2. APNS_KEY_PATH — a filesystem path to the .p8 file.
         Use this for local development.

    Returns the path to the key file, or None if neither is set.
    """
    import base64
    import tempfile

    content = os.getenv("APNS_KEY_CONTENT", "").strip()
    if content:
        try:
            key_bytes = base64.b64decode(content)
            tmp = tempfile.NamedTemporaryFile(delete=False, suffix=".p8", mode="wb")
            tmp.write(key_bytes)
            tmp.close()
            logger.info("APNs key written from APNS_KEY_CONTENT to %s", tmp.name)
            return tmp.name
        except Exception as e:
            logger.error("Failed to decode APNS_KEY_CONTENT: %s", e)
            return None

    path = os.getenv("APNS_KEY_PATH", "")
    if path and os.path.exists(path):
        return path

    return None


# ── App Lifecycle ─────────────────────────────────────────────────────────────
@asynccontextmanager
async def lifespan(app: FastAPI):
    global scraper, analyzer, pusher, registered_devices, SCAN_INTERVAL

    # Fail fast if required env vars are missing, then initialise Sentry
    validate_env()
    _init_sentry()

    # Restore persisted state before anything else
    _update_scan_cache(_load_scan_cache())
    registered_devices = _load_devices()
    watchlist_store.update(_load_watchlists())
    logger.info(f"Loaded {len(watchlist_store)} device watchlists from disk")
    settings = _load_settings()
    if "scan_interval" in settings and settings["scan_interval"] in ALLOWED_INTERVALS:
        SCAN_INTERVAL = settings["scan_interval"]
        logger.info(f"Restored scan interval: {SCAN_INTERVAL}s")
    logger.info(f"Loaded {len(registered_devices)} registered devices from disk")
    if last_scan["timestamp"]:
        logger.info(f"Restored scan cache from {last_scan['timestamp']}")

    scraper = RedditScraper(
        client_id=os.getenv("REDDIT_CLIENT_ID", ""),
        client_secret=os.getenv("REDDIT_CLIENT_SECRET", ""),
        user_agent=os.getenv("REDDIT_USER_AGENT", "StockPulse/1.0"),
    )
    analyzer = AIAnalyzer(api_key=os.environ["ANTHROPIC_API_KEY"])

    # APNs key: prefer APNS_KEY_CONTENT (base64-encoded .p8) for cloud deployments
    # where file paths don't persist; fall back to APNS_KEY_PATH for local dev.
    apns_key_path = _resolve_apns_key()
    if apns_key_path:
        pusher = APNsPusher(
            key_id=os.environ["APNS_KEY_ID"],
            team_id=os.environ["APNS_TEAM_ID"],
            bundle_id=os.environ["APNS_BUNDLE_ID"],
            key_path=apns_key_path,
            sandbox=os.getenv("APNS_SANDBOX", "true").lower() == "true",
        )
        logger.info("APNs pusher initialized")
    else:
        logger.warning("APNs key not found — push notifications disabled")

    asyncio.create_task(_run_scan_locked())
    scheduler.add_job(_run_scan_locked, "interval", seconds=SCAN_INTERVAL, id="reddit_scan")
    scheduler.start()
    logger.info(f"Scheduler started — scanning every {SCAN_INTERVAL}s")
    if not _CLIENT_API_KEY:
        logger.warning("CLIENT_API_KEY not set — app-facing endpoints are unprotected")
    if not _INGEST_API_KEY:
        logger.warning("INGEST_API_KEY not set — /scan/ingest and admin endpoints are unprotected")

    yield

    scheduler.shutdown()
    logger.info("Scheduler stopped")


# ── App ───────────────────────────────────────────────────────────────────────
app = FastAPI(
    title="StockPulse API",
    description="Reddit Stock Sentiment Tracker with AI Analysis",
    version="1.0.0",
    lifespan=lifespan,
)

app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_methods=["*"],
    allow_headers=["*"],
)


# ── Global exception handler ──────────────────────────────────────────────────
# Catches any unhandled exception in route handlers, logs it, sends it to
# Sentry, and returns a safe JSON 500 instead of leaking stack traces.

@app.exception_handler(Exception)
async def unhandled_exception_handler(request: Request, exc: Exception):
    logger.exception(
        "Unhandled exception on %s %s: %s", request.method, request.url.path, exc
    )
    _capture(exc)
    return JSONResponse(
        status_code=500,
        content={"error": "internal_server_error", "message": "An unexpected error occurred"},
    )


# ── Models ────────────────────────────────────────────────────────────────────
class RegisterDevice(BaseModel):
    device_token: str
    sandbox: bool = True


class TriggerScan(BaseModel):
    force: bool = False


# ── Public Routes ─────────────────────────────────────────────────────────────
@app.get("/health")
async def health():
    """
    Liveness + readiness probe.
    Returns scheduler state, last scan info, device count, and error-reporting status.
    Safe to call unauthenticated — contains no sensitive data.
    """
    job = scheduler.get_job("reddit_scan")
    return {
        "status": "ok",
        "version": "1.0.0",
        "environment": _ENV,
        "error_reporting": "sentry" if _SENTRY_DSN else "disabled",
        "scheduler_running": scheduler.running,
        "scan_interval_seconds": SCAN_INTERVAL,
        "next_scan_utc": str(job.next_run_time) if job else None,
        "last_scan_utc": last_scan.get("timestamp"),
        "last_scan_ticker_count": last_scan.get("raw_ticker_count", 0),
        "registered_devices": len(registered_devices),
    }


@app.get("/scan/latest")
async def get_latest_scan():
    if not last_scan["timestamp"]:
        # Return a valid empty structure (200) that Swift ScanResult can decode.
        # Keys must match the model: "results" (not "tickers"), timestamp as string.
        return Response(
            content=b'{"timestamp":"","results":[],"raw_ticker_count":0}',
            media_type="application/json",
        )
    # Serve pre-serialised bytes — zero JSON encoding overhead per request
    return Response(
        content=_scan_json_bytes,
        media_type="application/json",
        headers={"Cache-Control": _CACHE_HEADER},
    )


@app.get("/scan/top")
async def get_top_tickers(limit: int = 10, exclude_negative: bool = False):
    results = last_scan.get("results", [])
    if exclude_negative:
        results = [r for r in results if not r["negativeTraction"]]
    payload = json.dumps(
        {"timestamp": last_scan["timestamp"], "tickers": results[:limit]},
        separators=(",", ":"),
    ).encode()
    return Response(
        content=payload,
        media_type="application/json",
        headers={"Cache-Control": _CACHE_HEADER},
    )


@app.get("/scan/negative")
async def get_negative_tickers():
    results = [r for r in last_scan.get("results", []) if r["negativeTraction"]]
    payload = json.dumps(
        {"timestamp": last_scan["timestamp"], "tickers": results},
        separators=(",", ":"),
    ).encode()
    return Response(
        content=payload,
        media_type="application/json",
        headers={"Cache-Control": _CACHE_HEADER},
    )


@app.get("/ticker/{symbol}")
async def get_ticker_detail(symbol: str):
    symbol = symbol.upper()
    results = last_scan.get("results", [])
    match = next((r for r in results if r["ticker"] == symbol), None)
    if not match:
        raise HTTPException(status_code=404, detail=f"{symbol} not in latest scan")
    return Response(
        content=json.dumps(match, separators=(",", ":")).encode(),
        media_type="application/json",
        headers={"Cache-Control": _CACHE_HEADER},
    )


@app.get("/scan/schedule")
async def get_schedule():
    job = scheduler.get_job("reddit_scan")
    next_run = str(job.next_run_time) if job else "unknown"
    return {
        "interval_seconds": SCAN_INTERVAL,
        "next_run_utc": next_run,
        "registered_devices": len(registered_devices),
    }


class UpdateInterval(BaseModel):
    seconds: int


@app.patch("/scan/interval", dependencies=[Depends(require_ingest_key)])
async def update_scan_interval(payload: UpdateInterval):
    global SCAN_INTERVAL
    if payload.seconds not in ALLOWED_INTERVALS:
        raise HTTPException(
            status_code=400,
            detail=f"Interval must be one of {sorted(ALLOWED_INTERVALS)} seconds"
        )
    SCAN_INTERVAL = payload.seconds
    scheduler.reschedule_job("reddit_scan", trigger="interval", seconds=SCAN_INTERVAL)
    _save_settings({"scan_interval": SCAN_INTERVAL})
    logger.info(f"Scan interval updated to {SCAN_INTERVAL}s")
    return {"status": "updated", "interval_seconds": SCAN_INTERVAL}


# ── Protected Routes ──────────────────────────────────────────────────────────
@app.post("/devices/register", dependencies=[Depends(require_client_key)])
async def register_device(payload: RegisterDevice):
    registered_devices.add(payload.device_token)
    _save_devices(registered_devices)
    logger.info(
        f"Device registered: {payload.device_token[:12]}... "
        f"({len(registered_devices)} total)"
    )
    return {"status": "registered", "total_devices": len(registered_devices)}


@app.delete("/devices/{token}", dependencies=[Depends(require_ingest_key)])
async def unregister_device(token: str):
    registered_devices.discard(token)
    _save_devices(registered_devices)
    return {"status": "unregistered"}


_scan_lock = asyncio.Lock()

@app.post("/scan/trigger", dependencies=[Depends(require_client_key)])
async def trigger_scan(background_tasks: BackgroundTasks):
    if _scan_lock.locked():
        return {"status": "already_running", "message": "Scan already in progress — result will be ready shortly"}
    background_tasks.add_task(_run_scan_locked)
    return {"status": "scan_started", "message": "Scan running in background"}

async def _run_scan_locked():
    async with _scan_lock:
        await run_scan()


@app.post("/scan/ingest", dependencies=[Depends(require_ingest_key)])
async def ingest_scan(request: Request, payload: dict):
    """
    Receives a completed scan from the mac worker and caches it.
    Payload: { timestamp, results: [...], raw_ticker_count }
    Also fires push notifications and watchlist alerts, same as run_scan().
    """
    # Reject oversized payloads (defence against DoS / payload stuffing)
    content_length = request.headers.get("content-length")
    if content_length and int(content_length) > 1_048_576:  # 1 MB
        raise HTTPException(status_code=413, detail="Payload too large")

    global prev_scan_tickers, registered_devices
    required = {"timestamp", "results", "raw_ticker_count"}
    if not required.issubset(payload.keys()):
        raise HTTPException(status_code=400, detail=f"Missing fields: {required - payload.keys()}")

    # Sanitize tickers: replace any null in non-optional Swift fields with safe defaults
    # so the iOS decoder never receives JSON null for a required non-optional field.
    _STR_DEFAULTS = {
        "ticker": "", "companyName": "", "marketCap": "N/A",
        "sentimentLabel": "Neutral", "riskLevel": "Medium",
        "analystSummary": "", "recommendation": "WATCH",
    }
    _INT_DEFAULTS = {
        "totalMentions": 0, "bullishCount": 0, "bearishCount": 0,
        "neutralCount": 0, "investmentScore": 50, "sentimentScore": 50,
    }
    _FLOAT_DEFAULTS = {
        "currentPrice": 0.0, "priceChangePct": 0.0, "weekChangePct": 0.0,
        "volumeVsAvg": 1.0, "avgSentimentRaw": 0.0,
    }
    sanitized = []
    for r in payload.get("results", []):
        if not isinstance(r, dict) or not r.get("ticker"):
            continue
        for k, d in _STR_DEFAULTS.items():
            if not isinstance(r.get(k), str):
                r[k] = d
        for k, d in _INT_DEFAULTS.items():
            if not isinstance(r.get(k), int):
                r[k] = d
        for k, d in _FLOAT_DEFAULTS.items():
            v = r.get(k)
            if not isinstance(v, (int, float)) or not math.isfinite(v):
                r[k] = d
        if not isinstance(r.get("catalysts"), list):
            r["catalysts"] = []
        if not isinstance(r.get("topPosts"), list):
            r["topPosts"] = []
        r["redFlag"] = bool(r.get("redFlag"))
        r["negativeTraction"] = bool(r.get("negativeTraction"))
        sanitized.append(r)

    dropped = len(payload.get("results", [])) - len(sanitized)
    if dropped:
        logger.warning("Ingest: dropped %d malformed ticker(s)", dropped)
    payload["results"] = sanitized

    payload["source"] = "mac_worker"
    payload["ingested_at"] = datetime.utcnow().isoformat() + "Z"
    _update_scan_cache(payload)
    _save_scan_cache(last_scan)
    logger.info("Ingested scan from worker: %d tickers", len(payload["results"]))

    # Push notifications — same logic as run_scan()
    if pusher and registered_devices:
        # Re-hydrate enough info to send notifications
        ticker_names = [r["ticker"] for r in payload["results"]]
        current_ticker_set = set(ticker_names)
        newly_trending = current_ticker_set - prev_scan_tickers

        # Watchlist alerts
        if watchlist_store and newly_trending:
            expired_watchlist: set[str] = set()
            for device_token, watched in watchlist_store.items():
                for sym in set(watched) & newly_trending:
                    matching = next((r for r in payload["results"] if r["ticker"] == sym), None)
                    post_title = (matching.get("redditPosts") or [{}])[0].get("title") if matching else None
                    score = matching.get("investmentScore") if matching else None
                    result = pusher.send_watchlist_alert(device_token, sym, post_title, score)
                    if result == "expired":
                        expired_watchlist.add(device_token)
            if expired_watchlist:
                registered_devices -= expired_watchlist
                _save_devices(registered_devices)

        prev_scan_tickers = current_ticker_set

    return {"status": "ok", "tickers": len(payload["results"])}


class UpdateWatchlist(BaseModel):
    tickers: list[str]


@app.post("/devices/{token}/watchlist", dependencies=[Depends(require_client_key)])
async def update_device_watchlist(token: str, payload: UpdateWatchlist):
    """Store the list of tickers a device wants to be alerted about."""
    tickers = [t.upper().strip() for t in payload.tickers if t.strip()]
    if tickers:
        watchlist_store[token] = tickers
    else:
        watchlist_store.pop(token, None)
    _save_watchlists(watchlist_store)
    logger.info(f"Watchlist updated for {token[:12]}...: {tickers}")
    return {"status": "updated", "tickers": tickers}


if __name__ == "__main__":
    import uvicorn

    # Worker count: 1 on dev (APScheduler runs once per process).
    # For production deployments with many users, increase via env var
    # or use gunicorn: gunicorn main:app -w 4 -k uvicorn.workers.UvicornWorker
    # NOTE: APScheduler must only run in one worker — use an external scheduler
    # (e.g. Celery, APScheduler with job store) when deploying multi-worker.
    uvicorn.run(
        "main:app",
        host=os.getenv("HOST", "0.0.0.0"),  # nosec B104 noqa: S104 — intentional for server
        port=int(os.getenv("PORT", 8000)),
        reload=False,
        backlog=512,           # OS TCP accept queue — absorbs connection spikes
        timeout_keep_alive=5,  # release idle connections faster under load
        access_log=False,     # disable per-request access log in production (perf)
        log_level=os.getenv("LOG_LEVEL", "info").lower(),
    )
