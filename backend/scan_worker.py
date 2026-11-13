"""
scan_worker.py
--------------
Standalone scraper worker. Runs the full StockPulse pipeline:

  Fast sources  (every run — refresh matters at 15-min frequency):
    1. Reddit       — community sentiment from 9 investment subreddits
    2. StockTwits   — trending symbol ranks + message streams
    3. News RSS     — recent headlines via Yahoo Finance per-ticker RSS

  Slow sources  (cached — data doesn't change meaningfully in <hours):
    4. Google Trends — retail search interest spikes (0-100) — 6h cache
    5. SEC Form 4    — insider trading filings (last 30 days)  — 12h cache

Claude AI synthesises all 5 sources into investment analysis, then results
are POSTed to the Railway backend via /scan/ingest.

Cron (every 15 minutes):
  */15 * * * * cd /path/to/StockPulse/backend && source venv/bin/activate && python scan_worker.py >> /tmp/stockpulse_mac.log 2>&1

Required env vars (.env):
  ANTHROPIC_API_KEY   — Claude API key
  RAILWAY_URL         — e.g. https://stockpulse.up.railway.app
  INGEST_API_KEY      — Must match INGEST_API_KEY in Railway (worker-only key,
                         never shipped in the iOS app)
"""

import json
import logging
import os
import sys
from datetime import datetime, timezone
from pathlib import Path

import httpx
from dotenv import load_dotenv

# ── Bootstrap ─────────────────────────────────────────────────────────────────
_HERE = Path(__file__).parent
load_dotenv(_HERE / ".env", override=True)

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s %(levelname)s %(name)s — %(message)s",
    stream=sys.stdout,
)
logger = logging.getLogger("scan_worker")

# ── Config ────────────────────────────────────────────────────────────────────
RAILWAY_URL = os.getenv("RAILWAY_URL", "").rstrip("/")
INGEST_API_KEY = os.getenv("INGEST_API_KEY", "")
ANTHROPIC_API_KEY = os.getenv("ANTHROPIC_API_KEY", "")

TOP_N        = 40   # tickers to scrape from Reddit
ANALYZE_N    = 25   # top N sent to Claude
MIN_MENTIONS = 2    # minimum Reddit mentions to qualify

# Slow-source cache TTLs
_TRENDS_TTL  = 6  * 3600   # Google Trends  — 6 hours
_SEC_TTL     = 12 * 3600   # SEC EDGAR      — 12 hours
_CACHE_FILE  = _HERE / ".slow_cache.json"


# ── Slow-source cache helpers ─────────────────────────────────────────────────
def _load_cache() -> dict:
    try:
        if _CACHE_FILE.exists():
            return json.loads(_CACHE_FILE.read_text())
    except Exception as e:
        logger.warning("Could not load slow cache: %s", e)
    return {}


def _save_cache(cache: dict) -> None:
    try:
        _CACHE_FILE.write_text(json.dumps(cache))
    except Exception as e:
        logger.warning("Could not save slow cache: %s", e)


def _cache_fresh(cache: dict, key: str, ttl: int) -> tuple[bool, float]:
    """Returns (is_fresh, age_seconds). age is -1 if no entry exists."""
    entry = cache.get(key, {})
    cached_at = entry.get("cached_at")
    if not cached_at:
        return False, -1
    try:
        dt = datetime.fromisoformat(cached_at.replace("Z", "+00:00"))
        age = (datetime.now(timezone.utc) - dt).total_seconds()
        return age < ttl, age
    except Exception:
        return False, -1


# ── StockTwits ────────────────────────────────────────────────────────────────
def fetch_stocktwits_trending() -> dict[str, int]:
    try:
        with httpx.Client(timeout=15.0) as client:
            resp = client.get("https://api.stocktwits.com/api/2/trending/symbols.json")
            resp.raise_for_status()
            symbols = resp.json().get("symbols", [])
            return {s["symbol"]: i + 1 for i, s in enumerate(symbols)}
    except Exception as e:
        logger.warning("StockTwits trending fetch failed: %s", e)
        return {}


def fetch_stocktwits_streams(tickers: list[str]) -> dict[str, list[dict]]:
    streams: dict[str, list[dict]] = {}
    with httpx.Client(timeout=10.0) as client:
        for ticker in tickers:
            try:
                resp = client.get(
                    f"https://api.stocktwits.com/api/2/streams/symbol/{ticker}.json"
                )
                if resp.status_code == 429:
                    logger.warning("StockTwits rate limited — stopping stream fetches")
                    break
                if resp.status_code != 200:
                    streams[ticker] = []
                    continue
                messages = resp.json().get("messages", [])
                streams[ticker] = [
                    {
                        "stId": m["id"],
                        "body": m["body"],
                        "createdAt": m["created_at"],
                        "username": m["user"]["username"],
                        "likes": m.get("likes", {}).get("total", 0),
                        "sentiment": (
                            (m.get("entities") or {})
                            .get("sentiment") or {}
                        ).get("basic"),
                    }
                    for m in messages[:5]
                ]
            except Exception as e:
                logger.warning("StockTwits stream failed for %s: %s", ticker, e)
                streams[ticker] = []
    logger.info("StockTwits streams: fetched for %d tickers", len(streams))
    return streams


# ── Serialiser ────────────────────────────────────────────────────────────────
def analysis_to_dict(a) -> dict:
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
        "topPosts": [p.get("title", "") for p in a.top_posts] if a.top_posts else [],
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


# ── Main pipeline ─────────────────────────────────────────────────────────────
def validate_config() -> None:
    missing = []
    if not RAILWAY_URL:
        missing.append("RAILWAY_URL")
    if not ANTHROPIC_API_KEY:
        missing.append("ANTHROPIC_API_KEY")
    if missing:
        logger.critical("Missing required env vars: %s", ", ".join(missing))
        sys.exit(1)
    if not INGEST_API_KEY:
        logger.warning("INGEST_API_KEY not set — Railway endpoint must also have no INGEST_API_KEY")


def run() -> None:
    validate_config()

    from reddit_scraper import RedditScraper
    from ai_analyzer import AIAnalyzer

    logger.info("=== StockPulse scan worker starting ===")

    # ── Fast sources ──────────────────────────────────────────────────────────

    # 1. Reddit
    scraper = RedditScraper()
    logger.info("Scraping Reddit...")
    top_tickers = scraper.get_top_tickers(n=TOP_N, min_mentions=MIN_MENTIONS)
    logger.info("Scraped %d qualifying tickers", len(top_tickers))

    if not top_tickers:
        logger.warning("No tickers found — aborting")
        return

    ticker_symbols = [t.ticker for t in top_tickers[:ANALYZE_N]]

    # 2. StockTwits
    stocktwits_ranks = fetch_stocktwits_trending()
    logger.info("StockTwits trending: %d symbols", len(stocktwits_ranks))

    # 3. News RSS
    from news_rss_scraper import fetch_news_for_tickers
    news_items = fetch_news_for_tickers(ticker_symbols)

    # ── Slow sources (cached) ─────────────────────────────────────────────────
    now_iso = datetime.now(timezone.utc).isoformat().replace("+00:00", "Z")
    cache = _load_cache()
    cache_dirty = False

    # 4. Google Trends — refresh every 6 hours
    fresh, age = _cache_fresh(cache, "google_trends", _TRENDS_TTL)
    if fresh:
        trends_scores = cache["google_trends"]["data"]
        logger.info("Google Trends: using cache (%.0fm old, refreshes at 6h)", age / 60)
    else:
        logger.info("Google Trends: cache stale/missing — fetching...")
        from google_trends_scraper import fetch_google_trends
        trends_scores = fetch_google_trends(ticker_symbols)
        cache["google_trends"] = {"cached_at": now_iso, "data": trends_scores}
        cache_dirty = True

    # 5. SEC EDGAR — refresh every 12 hours
    fresh, age = _cache_fresh(cache, "sec_edgar", _SEC_TTL)
    if fresh:
        insider_data = cache["sec_edgar"]["data"]
        logger.info("SEC EDGAR: using cache (%.0fm old, refreshes at 12h)", age / 60)
    else:
        logger.info("SEC EDGAR: cache stale/missing — fetching...")
        from sec_edgar_scraper import fetch_insider_trades
        insider_data = fetch_insider_trades(ticker_symbols)
        cache["sec_edgar"] = {"cached_at": now_iso, "data": insider_data}
        cache_dirty = True

    if cache_dirty:
        _save_cache(cache)

    # ── AI analysis ───────────────────────────────────────────────────────────
    supplemental_data: dict[str, dict] = {
        ticker: {
            "stocktwitsRank":    stocktwits_ranks.get(ticker, 0),
            "googleTrendsScore": trends_scores.get(ticker, 0),
            "newsItems":         news_items.get(ticker, []),
            "insiderTradeCount": insider_data.get(ticker, {}).get("count", 0),
            "insiderTradeUrl":   insider_data.get(ticker, {}).get("edgarUrl", ""),
        }
        for ticker in ticker_symbols
    }

    analyzer = AIAnalyzer(api_key=ANTHROPIC_API_KEY)
    logger.info("Running AI analysis on top %d tickers...", min(ANALYZE_N, len(top_tickers)))
    analyses = analyzer.analyze(top_tickers[:ANALYZE_N], supplemental_data=supplemental_data)
    logger.info("Analysis complete: %d results", len(analyses))

    if not analyses:
        logger.warning("AI analysis returned 0 results — aborting")
        return

    # StockTwits streams for analyzed tickers only
    analyzed_symbols = [a.ticker for a in analyses]
    stocktwits_streams = fetch_stocktwits_streams(analyzed_symbols)

    # ── Build and POST payload ────────────────────────────────────────────────
    payload = {
        "timestamp": now_iso,
        "results": [
            {
                **analysis_to_dict(a),
                "stocktwitsRank":    stocktwits_ranks.get(a.ticker, 0),
                "stocktwitsMessages": stocktwits_streams.get(a.ticker, []),
                "googleTrendsScore": trends_scores.get(a.ticker, 0),
                "newsItems":         news_items.get(a.ticker, []),
                "insiderTradeCount": insider_data.get(a.ticker, {}).get("count", 0),
                "insiderTradeUrl":   insider_data.get(a.ticker, {}).get("edgarUrl", ""),
            }
            for a in analyses
        ],
        "raw_ticker_count": len(top_tickers),
    }

    ingest_url = f"{RAILWAY_URL}/scan/ingest"
    headers = {"Content-Type": "application/json"}
    if INGEST_API_KEY:
        headers["X-API-Key"] = INGEST_API_KEY

    logger.info("POSTing %d results to %s", len(analyses), ingest_url)
    try:
        with httpx.Client(timeout=30.0) as client:
            resp = client.post(ingest_url, content=json.dumps(payload), headers=headers)
        resp.raise_for_status()
        logger.info("Railway ingest response: %s", resp.json())
    except httpx.HTTPStatusError as e:
        logger.error("HTTP error posting to Railway: %s — %s", e.response.status_code, e.response.text)
        sys.exit(1)
    except Exception as e:
        logger.error("Failed to POST to Railway: %s", e)
        sys.exit(1)

    logger.info("=== Scan worker done ===")


if __name__ == "__main__":
    run()
