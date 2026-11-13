"""
news_rss_scraper.py
Fetch recent financial news headlines for stock tickers via yfinance's
built-in news API (Yahoo Finance v2 under the hood).
The old RSS feed URL was discontinued and returns 404.
"""

import logging
from datetime import datetime, timezone

logger = logging.getLogger(__name__)

MAX_ITEMS_PER_TICKER = 5


def fetch_news_for_tickers(tickers: list[str]) -> dict[str, list[dict]]:
    """
    Returns {TICKER: [news_items]} where each item is:
      {headline: str, source: str, url: str, publishedAt: str (ISO 8601)}
    Falls back to empty list per ticker on any error.
    """
    try:
        import yfinance as yf
    except ImportError:
        logger.warning("yfinance not installed — skipping news fetch")
        return {t: [] for t in tickers}

    results: dict[str, list[dict]] = {}
    for ticker in tickers:
        try:
            raw_news = yf.Ticker(ticker).news or []
            items = []
            for article in raw_news[:MAX_ITEMS_PER_TICKER]:
                # yfinance 1.x wraps everything under article["content"]
                content = article.get("content") or article  # fall back to flat for older builds

                headline = (content.get("title") or "").strip()
                if not headline:
                    continue

                # pubDate is already ISO 8601 in 1.x; older builds used providerPublishTime (Unix)
                pub_date = content.get("pubDate") or content.get("displayTime") or ""
                if not pub_date:
                    pub_ts = article.get("providerPublishTime") or 0
                    if pub_ts:
                        pub_date = datetime.fromtimestamp(pub_ts, tz=timezone.utc).isoformat()

                provider = content.get("provider") or {}
                source = provider.get("displayName") or article.get("publisher") or "Yahoo Finance"

                click_url = content.get("clickThroughUrl") or content.get("canonicalUrl") or {}
                url = click_url.get("url") or article.get("link") or article.get("url", "")

                items.append(
                    {
                        "headline": headline,
                        "source": source,
                        "url": url,
                        "publishedAt": pub_date,
                    }
                )
            results[ticker] = items
        except Exception as e:
            logger.warning("News fetch failed for %s: %s", ticker, e)
            results[ticker] = []

    total = sum(len(v) for v in results.values())
    logger.info("News: %d articles across %d tickers", total, len(tickers))
    return results
