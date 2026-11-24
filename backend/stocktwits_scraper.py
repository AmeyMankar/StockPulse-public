"""
stocktwits_scraper.py
---------------------
Ticker discovery and sentiment from StockTwits' public API (no credentials).

Strategy:
  1. /trending/symbols.json            -> which tickers are being discussed most
  2. /streams/symbol/{ticker}.json     -> recent messages for each (one request each)
  3. Sentiment per message: the author's own Bullish/Bearish tag when present,
     otherwise VADER on the message text.

Volume: 1 + up to MAX_SYMBOLS requests per run, spaced REQ_INTERVAL apart.
At one run per 15 minutes this stays well inside StockTwits' unauthenticated
limit (200 requests/hour). The fetched streams are kept on the scraper
instance so the worker does not need to request them a second time.
"""

import logging
import re
import time
from dataclasses import dataclass, field

import httpx
from vaderSentiment.vaderSentiment import SentimentIntensityAnalyzer

logger = logging.getLogger(__name__)

API_BASE = "https://api.stocktwits.com/api/2"
MAX_SYMBOLS = 30          # streams fetched per run
MESSAGES_PER_STREAM = 30  # StockTwits returns up to 30 per page
REQ_INTERVAL = 0.5        # seconds between requests
_TICKER_OK = re.compile(r"^[A-Z]{1,5}$")   # drops crypto ("BTC.X") and odd symbols


@dataclass
class AggregatedTicker:
    ticker: str
    total_mentions: int = 0
    post_mentions: int = 0
    comment_mentions: int = 0
    subreddits: dict = field(default_factory=dict)   # legacy field, kept so the API shape is unchanged
    avg_sentiment: float = 0.0
    sentiment_scores: list = field(default_factory=list)
    top_posts: list = field(default_factory=list)    # [{title, url, score}]
    total_post_karma: int = 0
    bullish_count: int = 0
    bearish_count: int = 0
    neutral_count: int = 0


class StockTwitsScraper:
    def __init__(self, **kwargs):
        self.vader = SentimentIntensityAnalyzer()
        self.trending_ranks: dict[str, int] = {}
        self.streams: dict[str, list[dict]] = {}     # ticker -> messages in worker/app format
        logger.info("StockTwits scraper initialized")

    # ── helpers ───────────────────────────────────────────────────────────────
    @staticmethod
    def _snippet(text: str, max_len: int = 140) -> str:
        text = " ".join((text or "").split())
        return text[:max_len] + ("..." if len(text) > max_len else "")

    def _message_sentiment(self, msg: dict) -> float:
        tag = ((msg.get("entities") or {}).get("sentiment") or {}).get("basic")
        if tag == "Bullish":
            return 0.6
        if tag == "Bearish":
            return -0.6
        return self.vader.polarity_scores(msg.get("body", ""))["compound"]

    def fetch_trending(self, client: httpx.Client) -> dict[str, int]:
        try:
            resp = client.get(f"{API_BASE}/trending/symbols.json")
            resp.raise_for_status()
            symbols = resp.json().get("symbols", [])
        except Exception as e:
            logger.warning("StockTwits trending fetch failed: %s", e)
            return {}
        ranks: dict[str, int] = {}
        for s in symbols:
            sym = s.get("symbol", "")
            if _TICKER_OK.match(sym) and sym not in ranks:
                ranks[sym] = len(ranks) + 1
        return ranks

    def fetch_stream(self, client: httpx.Client, ticker: str) -> list[dict] | None:
        """Returns raw messages, [] if the symbol has none, None if rate limited."""
        try:
            resp = client.get(f"{API_BASE}/streams/symbol/{ticker}.json")
        except Exception as e:
            logger.warning("StockTwits stream failed for %s: %s", ticker, e)
            return []
        if resp.status_code == 429:
            return None
        if resp.status_code != 200:
            return []
        return resp.json().get("messages", [])[:MESSAGES_PER_STREAM]

    def _aggregate(self, ticker: str, messages: list[dict]) -> AggregatedTicker:
        agg = AggregatedTicker(ticker=ticker)
        for m in messages:
            score = self._message_sentiment(m)
            agg.sentiment_scores.append(score)
            agg.total_mentions += 1
            agg.post_mentions += 1
            if score >= 0.05:
                agg.bullish_count += 1
            elif score <= -0.05:
                agg.bearish_count += 1
            else:
                agg.neutral_count += 1

        if agg.sentiment_scores:
            agg.avg_sentiment = round(sum(agg.sentiment_scores) / len(agg.sentiment_scores), 4)

        # Up to 5 most-liked messages, each linking back to the original on StockTwits.
        by_likes = sorted(
            messages, key=lambda m: (m.get("likes") or {}).get("total", 0), reverse=True
        )
        for m in by_likes[:5]:
            user = (m.get("user") or {}).get("username", "")
            if not user or not m.get("id"):
                continue
            likes = (m.get("likes") or {}).get("total", 0)
            agg.top_posts.append({
                "title": self._snippet(m.get("body", "")),
                "url": f"https://stocktwits.com/{user}/message/{m['id']}",
                "score": likes,
            })
            agg.total_post_karma += likes
        return agg

    # ── public API ────────────────────────────────────────────────────────────
    def get_top_tickers(self, n: int = 20, min_mentions: int = 2) -> list[AggregatedTicker]:
        """Trending tickers in StockTwits trending order, with sentiment from recent messages."""
        results: list[AggregatedTicker] = []
        self.streams = {}

        with httpx.Client(timeout=15.0, follow_redirects=True) as client:
            self.trending_ranks = self.fetch_trending(client)
            logger.info("StockTwits trending: %d symbols", len(self.trending_ranks))

            for ticker in list(self.trending_ranks)[:min(n, MAX_SYMBOLS)]:
                time.sleep(REQ_INTERVAL)
                messages = self.fetch_stream(client, ticker)
                if messages is None:
                    logger.warning("StockTwits rate limited — stopping stream fetches")
                    break
                self.streams[ticker] = [
                    {
                        "stId": m["id"],
                        "body": m["body"],
                        "createdAt": m["created_at"],
                        "username": (m.get("user") or {}).get("username", ""),
                        "likes": (m.get("likes") or {}).get("total", 0),
                        "sentiment": ((m.get("entities") or {}).get("sentiment") or {}).get("basic"),
                    }
                    for m in messages[:5]
                ]
                agg = self._aggregate(ticker, messages)
                if agg.total_mentions >= min_mentions:
                    results.append(agg)

        logger.info("StockTwits: %d qualifying tickers", len(results))
        return results[:n]
