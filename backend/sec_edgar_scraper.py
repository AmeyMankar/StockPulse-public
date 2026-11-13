"""
sec_edgar_scraper.py
Fetch recent Form 4 insider-trading filings from SEC EDGAR.
Uses the public EDGAR REST API — no API key required.
SEC requires a descriptive User-Agent with contact info per their fair-use policy.
"""

import logging
from datetime import datetime, timedelta, timezone
from functools import lru_cache

import httpx

logger = logging.getLogger(__name__)

EDGAR_HEADERS = {
    "User-Agent": "StockPulse stockpulse.app.help@gmail.com",
    "Accept-Encoding": "gzip, deflate",
}
EDGAR_SEARCH_URL = (
    "https://efts.sec.gov/LATEST/search-index"
    "?q=%22{ticker}%22&forms=4&dateRange=custom&startdt={startdt}&enddt={enddt}"
)
EDGAR_TICKER_PAGE = "https://www.sec.gov/cgi-bin/browse-edgar?action=getcompany&CIK={ticker}&type=4&dateb=&owner=include&count=5"


@lru_cache(maxsize=1)
def _load_cik_map() -> dict[str, str]:
    """Download and cache the full ticker→CIK mapping from EDGAR (one-time per process)."""
    try:
        with httpx.Client(timeout=20.0, headers=EDGAR_HEADERS) as client:
            resp = client.get("https://www.sec.gov/files/company_tickers.json")
            resp.raise_for_status()
            data = resp.json()
            # Format: {"0": {cik_str, ticker, title}, "1": {...}, ...}
            return {
                str(v["ticker"]).upper(): str(v["cik_str"]).zfill(10)
                for v in data.values()
            }
    except Exception as e:
        logger.warning("Failed to load EDGAR CIK map: %s", e)
        return {}


def fetch_insider_trades(
    tickers: list[str], lookback_days: int = 30
) -> dict[str, dict]:
    """
    Returns {TICKER: {count, edgarUrl}} for recent Form 4 filings.
      count    — number of Form 4s filed in the last `lookback_days`
      edgarUrl — direct link to the EDGAR filing search for this ticker
    Falls back to {count: 0} per ticker on error.
    """
    if not tickers:
        return {}

    cik_map = _load_cik_map()
    results: dict[str, dict] = {}

    cutoff = (
        datetime.now(timezone.utc) - timedelta(days=lookback_days)
    ).strftime("%Y-%m-%d")
    today = datetime.now(timezone.utc).strftime("%Y-%m-%d")

    with httpx.Client(timeout=15.0, headers=EDGAR_HEADERS) as client:
        for ticker in tickers:
            cik = cik_map.get(ticker.upper())
            edgar_url = EDGAR_TICKER_PAGE.format(ticker=ticker)

            if not cik:
                results[ticker] = {"count": 0, "edgarUrl": edgar_url}
                continue

            try:
                url = f"https://data.sec.gov/submissions/CIK{cik}.json"
                resp = client.get(url)
                if resp.status_code != 200:
                    results[ticker] = {"count": 0, "edgarUrl": edgar_url}
                    continue

                data = resp.json()
                recent = data.get("filings", {}).get("recent", {})
                forms = recent.get("form", [])
                dates = recent.get("filingDate", [])

                count = sum(
                    1
                    for form, date in zip(forms, dates)
                    if form == "4" and date >= cutoff
                )
                results[ticker] = {"count": count, "edgarUrl": edgar_url}

            except Exception as e:
                logger.warning("SEC EDGAR failed for %s: %s", ticker, e)
                results[ticker] = {"count": 0, "edgarUrl": edgar_url}

    active = sum(1 for v in results.values() if v["count"] > 0)
    logger.info(
        "SEC EDGAR: %d/%d tickers with recent Form 4 activity", active, len(tickers)
    )
    return results
