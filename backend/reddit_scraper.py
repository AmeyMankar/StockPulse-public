"""
reddit_scraper.py
-----------------
Scrapes target subreddits for stock ticker mentions using
old.reddit.com HTML (no API credentials required).

Strategy:
  1. Fetch /hot/ listing per subreddit → get top post permalinks + titles
  2. Fetch each post's comment page → extract comments
  3. Mine tickers from titles + comments

Parallelism: all subreddits scraped concurrently via ThreadPoolExecutor.
Rate limit: 1 request/second global across all threads.
"""

import re
import time
import logging
import threading
from concurrent.futures import ThreadPoolExecutor, as_completed
from dataclasses import dataclass, field
from datetime import datetime, timezone

import httpx
from bs4 import BeautifulSoup
from vaderSentiment.vaderSentiment import SentimentIntensityAnalyzer

logger = logging.getLogger(__name__)

OLD_REDDIT_BASE = "https://old.reddit.com"

_HEADERS = {
    "User-Agent": "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7; rv:120.0) Gecko/20100101 Firefox/120.0",
    "Accept": "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
    "Accept-Language": "en-US,en;q=0.5",
    "Accept-Encoding": "gzip, deflate, br",
    "DNT": "1",
}

TARGET_SUBS = [
    "wallstreetbets",
    "stocks",
    "pennystocks",
    "stockstobuytoday",
    "stockmarket",
    "investing",
    "options",
    "Daytrading",
    "smallcapstocks",
]

BLACKLIST = {
    # Single letters & very common words
    "A", "I", "AM", "AN", "BE", "BY", "DD", "DO", "EV", "FD", "GO",
    "HE", "IF", "IN", "IS", "IT", "ME", "MY", "NO", "OF", "ON", "OR",
    "SO", "TO", "UP", "US", "WE",
    # Job titles / corporate roles
    "CEO", "CFO", "CTO", "COO", "CMO", "CIO", "EVP", "SVP", "VP", "GM",
    # Finance & market jargon (not tickers)
    "IPO", "ETF", "OTC", "OTM", "ITM", "GDP", "CPI", "PPI", "NFP",
    "QE", "QT", "FOMC", "FED", "ECB", "IMF", "SEC", "FDA", "IRS",
    "EPS", "PE", "PEG", "ROE", "ROI", "IRR", "DCF", "NAV", "AUM",
    "YTD", "QOQ", "YOY", "ITD", "MOM",
    "APR", "ATH", "ATL", "RATE", "DEBT",
    # Fiat currencies
    "USD", "EUR", "GBP", "JPY", "CHF", "CNY", "INR", "MXN", "BRL",
    # Crypto tokens
    "BTC", "ETH", "NFT", "DAO", "DOGE", "SHIB",
    "SOL", "XRP", "ADA", "AVAX", "MATIC", "LINK", "DOT", "UNI", "AAVE",
    "LTC", "BCH", "XLM", "ALGO", "ATOM", "FTM", "NEAR", "ICP", "VET",
    "SAND", "MANA", "AXS", "GALA", "ENJ", "CHZ", "FLOW", "THETA",
    "XMR", "ZEC", "DASH", "ETC", "EOS", "TRX", "XTZ", "CAKE", "SUSHI",
    "PEPE", "BONK", "WIF", "FLOKI", "SAFEMOON",
    # Crypto concepts
    "DEFI", "DAPP", "DAPPS", "STAKING", "MINING", "WALLET", "DEX", "CEX",
    "CBDC", "USDT", "USDC", "BUSD", "DAI", "WBTC",
    # Credit ratings
    "AAA", "BBB", "CCC",
    # Region / country codes
    "UK", "EU",
    # Tech abbreviations
    "IP", "OS", "PC", "TV", "API", "SDK",
    # Reddit / internet slang
    "DM", "OP", "PM", "TL", "DR", "PS", "VS", "RE",
    "LOL", "WTF", "OMG", "TBH", "FYI", "IMO", "NVM",
    "LFG", "WAGMI", "HODL", "FOMO", "YOLO", "DCA", "AMA",
    "TLDR", "WSB", "EOD", "EOW",
    # Bull/bear market slang
    "BUY", "PUT", "CALL", "BULL", "BEAR", "HOLD",
    "MOON", "PUMP", "DUMP", "LOSS", "GAIN",
    "HIGH", "LOW", "NEWS",
    # Generic English words
    "ALL", "FOR", "THE", "NEW", "NOW", "NEXT", "LAST", "GOOD", "BEST",
    "ABOUT", "BASED", "TOTAL", "STOCK", "SHARE", "PRICE",
    "MARKET", "TRADE", "EDIT", "UPDATE",
    # AI / tech
    "AI", "ML",
}

TICKER_RE = re.compile(r'\$([A-Z]{1,5})\b|\b([A-Z]{2,5})\b')

REQ_INTERVAL = 1.0
HOT_POST_LIMIT = 10      # posts to scrape from each subreddit's hot listing
COMMENTS_PER_POST = 30   # max comments to read per post


class _RateLimiter:
    def __init__(self, interval: float = REQ_INTERVAL) -> None:
        self._interval = interval
        self._lock = threading.Lock()
        self._last: float = 0.0

    def acquire(self) -> None:
        with self._lock:
            now = time.monotonic()
            wait = self._interval - (now - self._last)
            if wait > 0:
                time.sleep(wait)
            self._last = time.monotonic()


@dataclass
class TickerMention:
    ticker: str
    subreddit: str
    post_id: str
    post_title: str
    post_score: int
    post_url: str
    context: str
    sentiment_raw: float
    is_comment: bool
    created_utc: float


@dataclass
class AggregatedTicker:
    ticker: str
    total_mentions: int = 0
    post_mentions: int = 0
    comment_mentions: int = 0
    subreddits: dict = field(default_factory=dict)
    avg_sentiment: float = 0.0
    sentiment_scores: list = field(default_factory=list)
    top_posts: list = field(default_factory=list)
    total_post_karma: int = 0
    bullish_count: int = 0
    bearish_count: int = 0
    neutral_count: int = 0


class RedditScraper:
    def __init__(self, **kwargs):
        self.vader = SentimentIntensityAnalyzer()
        self._rate_limiter = _RateLimiter(REQ_INTERVAL)
        self._local = threading.local()
        logger.info("Reddit scraper initialized (old.reddit.com HTML + comments)")

    @property
    def _client(self) -> httpx.Client:
        if not hasattr(self._local, "client"):
            self._local.client = httpx.Client(
                headers=_HEADERS,
                timeout=30.0,
                follow_redirects=True,
                verify=True,
                limits=httpx.Limits(
                    max_connections=5,
                    max_keepalive_connections=3,
                    keepalive_expiry=30,
                ),
            )
        return self._local.client

    def _get_html(self, url: str) -> str | None:
        self._rate_limiter.acquire()
        try:
            resp = self._client.get(url)
            if resp.status_code == 429:
                retry_after = int(resp.headers.get("retry-after", 10))
                logger.warning("Rate limited — backing off %ds", retry_after)
                time.sleep(retry_after)
                self._rate_limiter.acquire()
                resp = self._client.get(url)
            resp.raise_for_status()
            if "reddit" not in resp.text[:500].lower():
                logger.error("Unexpected response from %s — may be blocked", url)
                return None
            return resp.text
        except Exception as e:
            logger.warning("GET %s failed: %s", url, e)
            return None

    def _extract_tickers(self, text: str) -> list[str]:
        found = set()
        for match in TICKER_RE.finditer(text):
            ticker = match.group(1) or match.group(2)
            if ticker and ticker not in BLACKLIST and len(ticker) >= 2:
                found.add(ticker)
        return list(found)

    def _sentiment(self, text: str) -> float:
        return self.vader.polarity_scores(text)["compound"]

    def _snippet(self, text: str, max_len: int = 200) -> str:
        text = text.strip().replace("\n", " ")
        return text[:max_len] + ("..." if len(text) > max_len else "")

    def _parse_timestamp(self, time_el) -> float:
        if not time_el:
            return 0.0
        ts_str = time_el.get("datetime", "")
        try:
            dt = datetime.fromisoformat(ts_str.replace("Z", "+00:00"))
            return dt.timestamp()
        except Exception:
            return 0.0

    def scrape_subreddit(self, subreddit_name: str, **kwargs) -> list[TickerMention]:
        mentions: list[TickerMention] = []

        # ── Step 1: hot listing ──────────────────────────────────────────────
        html = self._get_html(f"{OLD_REDDIT_BASE}/r/{subreddit_name}/hot/")
        if not html:
            logger.error("Failed to fetch r/%s listing", subreddit_name)
            return mentions

        soup = BeautifulSoup(html, "html.parser")
        things = [
            t for t in soup.find_all("div", class_="thing")
            if "stickied" not in t.get("class", [])
        ][:HOT_POST_LIMIT]

        if not things:
            logger.warning("r/%s: no posts parsed from listing", subreddit_name)
            return mentions

        # Log freshness
        time_el = things[0].find("time")
        if time_el:
            ts = self._parse_timestamp(time_el)
            if ts:
                age_h = (datetime.now(timezone.utc).timestamp() - ts) / 3600
                logger.info("r/%s: newest hot post is %.1fh old", subreddit_name, age_h)

        logger.info("r/%s: %d posts in hot listing", subreddit_name, len(things))

        # ── Step 2: for each post, fetch title + comments ────────────────────
        for thing in things:
            title_el = thing.find("a", class_="title")
            if not title_el:
                continue
            title = title_el.text.strip()
            if title in ("", "[deleted]", "[removed]"):
                continue

            post_id = thing.get("data-fullname", "")
            permalink = thing.get("data-permalink", "")
            post_url = f"{OLD_REDDIT_BASE}{permalink}" if permalink else ""

            score_el = (
                thing.find("div", class_="score unvoted")
                or thing.find("div", class_="score likes")
            )
            try:
                score = int(score_el.text.replace(",", "").strip()) if score_el else 0
            except (ValueError, AttributeError):
                score = 0

            created_utc = self._parse_timestamp(thing.find("time"))

            # Mine tickers from title
            title_tickers = self._extract_tickers(title)
            for ticker in title_tickers:
                mentions.append(TickerMention(
                    ticker=ticker,
                    subreddit=subreddit_name,
                    post_id=post_id,
                    post_title=self._snippet(title, 120),
                    post_score=score,
                    post_url=post_url,
                    context=self._snippet(title),
                    sentiment_raw=self._sentiment(title),
                    is_comment=False,
                    created_utc=created_utc,
                ))

            # Fetch comments page
            if not permalink:
                continue
            comment_html = self._get_html(f"{OLD_REDDIT_BASE}{permalink}")
            if not comment_html:
                continue

            comment_soup = BeautifulSoup(comment_html, "html.parser")
            comment_divs = comment_soup.find_all("div", class_="comment", limit=COMMENTS_PER_POST)

            for cdiv in comment_divs:
                body_el = cdiv.find("div", class_="md")
                if not body_el:
                    continue
                comment_text = body_el.get_text(" ", strip=True)
                if not comment_text or comment_text in ("[deleted]", "[removed]"):
                    continue

                comment_tickers = self._extract_tickers(comment_text)
                comment_time_el = cdiv.find("time")
                comment_ts = self._parse_timestamp(comment_time_el)

                for ticker in comment_tickers:
                    mentions.append(TickerMention(
                        ticker=ticker,
                        subreddit=subreddit_name,
                        post_id=post_id,
                        post_title=self._snippet(title, 120),
                        post_score=score,
                        post_url=post_url,
                        context=self._snippet(comment_text),
                        sentiment_raw=self._sentiment(comment_text),
                        is_comment=True,
                        created_utc=comment_ts or created_utc,
                    ))

        post_count = sum(1 for m in mentions if not m.is_comment)
        comment_count = sum(1 for m in mentions if m.is_comment)
        logger.info(
            "r/%s: %d title mentions + %d comment mentions",
            subreddit_name, post_count, comment_count,
        )
        return mentions

    def scrape_all(self, **kwargs) -> dict[str, AggregatedTicker]:
        all_mentions: list[TickerMention] = []

        with ThreadPoolExecutor(
            max_workers=len(TARGET_SUBS),
            thread_name_prefix="reddit-scraper",
        ) as pool:
            futures = {
                pool.submit(self.scrape_subreddit, sub): sub
                for sub in TARGET_SUBS
            }
            for future in as_completed(futures):
                sub = futures[future]
                try:
                    all_mentions.extend(future.result())
                except Exception as exc:
                    logger.error("Subreddit %s scrape raised: %s", sub, exc)

        aggregated: dict[str, AggregatedTicker] = {}

        for m in all_mentions:
            if m.ticker not in aggregated:
                aggregated[m.ticker] = AggregatedTicker(ticker=m.ticker)
            agg = aggregated[m.ticker]
            agg.total_mentions += 1
            agg.sentiment_scores.append(m.sentiment_raw)

            if m.is_comment:
                agg.comment_mentions += 1
            else:
                agg.post_mentions += 1
                agg.total_post_karma += m.post_score
                existing_urls = {p["url"] for p in agg.top_posts}
                if len(agg.top_posts) < 5 and m.post_url not in existing_urls:
                    agg.top_posts.append({
                        "title": m.post_title,
                        "url": m.post_url,
                        "score": m.post_score,
                    })

            agg.subreddits[m.subreddit] = agg.subreddits.get(m.subreddit, 0) + 1

            if m.sentiment_raw >= 0.05:
                agg.bullish_count += 1
            elif m.sentiment_raw <= -0.05:
                agg.bearish_count += 1
            else:
                agg.neutral_count += 1

        for agg in aggregated.values():
            if agg.sentiment_scores:
                agg.avg_sentiment = round(
                    sum(agg.sentiment_scores) / len(agg.sentiment_scores), 4
                )
            agg.subreddits = {k: v for k, v in agg.subreddits.items() if v >= 2}

        logger.info("Total unique tickers found: %d", len(aggregated))
        return dict(aggregated)

    def get_top_tickers(self, n: int = 20, min_mentions: int = 2) -> list[AggregatedTicker]:
        aggregated = self.scrape_all()
        filtered = [t for t in aggregated.values() if t.total_mentions >= min_mentions]
        return sorted(filtered, key=lambda x: x.total_mentions, reverse=True)[:n]

    def __del__(self):
        try:
            if hasattr(self._local, "client"):
                self._local.client.close()
        except Exception:
            pass
