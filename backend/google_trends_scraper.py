"""
google_trends_scraper.py
Fetch Google search interest scores for stock tickers using pytrends.
Returns a 0-100 relative interest score (Google's scale) over the last 7 days.
"""

import logging
import time
import random

logger = logging.getLogger(__name__)

_BATCH_SLEEP   = 30   # seconds between batches (Google rate-limits aggressively)
_RETRY_SLEEP   = 90   # seconds to wait after a 429 before retrying
_MAX_RETRIES   = 1    # retry once per batch


def fetch_google_trends(tickers: list[str]) -> dict[str, int]:
    """
    Returns {TICKER: interest_score} where score is 0-100.
    A score of 100 = peak search interest; 0 = negligible interest.
    Falls back to empty dict on any error — never blocks the pipeline.
    """
    if not tickers:
        return {}

    try:
        from pytrends.request import TrendReq
    except ImportError:
        logger.warning("pytrends not installed — skipping Google Trends")
        return {}

    results: dict[str, int] = {}
    try:
        pytrends = TrendReq(hl="en-US", tz=300, timeout=(10, 25), retries=2, backoff_factor=0.5)
    except Exception as e:
        logger.warning("pytrends init failed: %s", e)
        return {}

    batches = [tickers[i: i + 5] for i in range(0, len(tickers), 5)]

    for idx, batch in enumerate(batches):
        for attempt in range(_MAX_RETRIES + 1):
            try:
                pytrends.build_payload(batch, timeframe="now 7-d", geo="US")
                data = pytrends.interest_over_time()
                if not data.empty:
                    for ticker in batch:
                        if ticker in data.columns:
                            score = int(data[ticker].iloc[-1])
                            if score > 0:
                                results[ticker] = score
                break  # success — move to next batch
            except Exception as e:
                is_429 = "429" in str(e)
                if is_429 and attempt < _MAX_RETRIES:
                    wait = _RETRY_SLEEP + random.randint(0, 30)
                    logger.warning(
                        "Google Trends 429 for batch %s — retrying in %ds", batch, wait
                    )
                    time.sleep(wait)
                else:
                    logger.warning("Google Trends failed for batch %s: %s", batch, e)
                    break

        if idx < len(batches) - 1:
            sleep = _BATCH_SLEEP + random.randint(0, 10)
            logger.debug("Google Trends: sleeping %ds before next batch", sleep)
            time.sleep(sleep)

    logger.info("Google Trends: scores for %d/%d tickers", len(results), len(tickers))
    return results
