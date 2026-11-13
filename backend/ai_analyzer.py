"""
ai_analyzer.py
--------------
Uses Anthropic Claude to generate deep investment analysis
for each top ticker based on Reddit mention data + price info.
"""

import json
import logging
import math
from concurrent.futures import ThreadPoolExecutor, as_completed

import yfinance as yf
from anthropic import Anthropic
from dataclasses import dataclass
from reddit_scraper import AggregatedTicker

logger = logging.getLogger(__name__)


@dataclass
class TickerAnalysis:
    ticker: str
    company_name: str
    current_price: float
    price_change_pct: float        # 1-day % change
    week_change_pct: float         # 5-day % change
    volume_vs_avg: float           # current vol / avg vol ratio
    market_cap: str                # human readable e.g. "$1.2B"
    total_mentions: int
    subreddit_breakdown: dict
    avg_sentiment_raw: float       # VADER -1 to +1
    bullish_count: int
    bearish_count: int
    neutral_count: int
    top_posts: list[dict]   # each: {title: str, url: str, score: int}
    # AI-generated fields
    investment_score: int          # 1-100
    sentiment_score: int           # 1-100 (50=neutral)
    sentiment_label: str           # Bullish/Bearish/Neutral/Strongly Bullish/Strongly Bearish
    risk_level: str                # Low/Medium/High/Extreme
    analyst_summary: str           # 2-3 sentence analysis
    catalysts: list[str]           # 2-4 bullet points
    red_flag: bool
    negative_traction: bool
    recommendation: str            # BUY / WATCH / AVOID / SHORT_WATCH


def _human_market_cap(mc: float | None) -> str:
    if not mc:
        return "N/A"
    if mc >= 1e12:
        return f"${mc/1e12:.1f}T"
    if mc >= 1e9:
        return f"${mc/1e9:.1f}B"
    if mc >= 1e6:
        return f"${mc/1e6:.1f}M"
    return f"${mc:.0f}"


def fetch_price_data(ticker: str) -> dict:
    """Fetch current price, change %, volume from Yahoo Finance (yfinance 1.x)."""
    try:
        t = yf.Ticker(ticker)
        hist = t.history(period="5d")
        fast_info = t.fast_info

        if hist.empty or len(hist) < 2:
            return {}

        current_price = float(hist["Close"].iloc[-1])
        prev_close = float(hist["Close"].iloc[-2])

        # Guard against NaN/Inf from yfinance gaps — treat ticker as unrecognized
        if not (math.isfinite(current_price) and math.isfinite(prev_close) and prev_close != 0):
            logger.warning("Non-finite price data for %s (price=%s prev=%s) — skipping", ticker, current_price, prev_close)
            return {}

        day_change = ((current_price - prev_close) / prev_close) * 100
        first_close = float(hist["Close"].iloc[0])
        week_change = ((current_price - first_close) / first_close * 100) if math.isfinite(first_close) and first_close != 0 else 0.0

        avg_vol = hist["Volume"].mean()
        curr_vol = float(hist["Volume"].iloc[-1])
        vol_ratio = curr_vol / avg_vol if (math.isfinite(avg_vol) and avg_vol > 0) else 1.0

        mc_raw = getattr(fast_info, "market_cap", None)

        # Company name: yfinance 1.x removed quote_type from fast_info;
        # use shortName from info dict (cached by yfinance, one extra call).
        try:
            company_name = t.info.get("shortName") or t.info.get("longName") or ticker
        except Exception:
            company_name = ticker

        return {
            "current_price": round(current_price, 2),
            "price_change_pct": round(day_change, 2),
            "week_change_pct": round(week_change, 2),
            "volume_vs_avg": round(vol_ratio, 2),
            "market_cap": _human_market_cap(mc_raw),
            "market_cap_raw": mc_raw or 0,
            "company_name": company_name,
        }
    except Exception as e:
        logger.warning(f"Price fetch failed for {ticker}: {e}")
        return {}


ANALYSIS_SYSTEM_PROMPT = (
    "You are a seasoned quantitative equity analyst. "
    "You receive structured data about stock tickers aggregated from 5 sources:\n"
    "  1. Reddit — community discussion and social sentiment from investment subreddits\n"
    "  2. StockTwits — financial social media trader sentiment and trending rank\n"
    "  3. Google Trends — retail search interest (0-100 scale, US, last 7 days)\n"
    "  4. News RSS — recent financial headlines from Yahoo Finance and major outlets\n"
    "  5. SEC Form 4 — insider trading filings (executives/directors buying or selling)\n\n"
    "Weighting guidance:\n"
    "- Google Trends score >70: strong retail-interest spike, often precedes price moves.\n"
    "- SEC Form 4 count >0: insiders are active — buying is a strong bullish signal, "
    "selling is mixed (could be diversification).\n"
    "- Negative news headlines: raise risk level accordingly.\n"
    "- StockTwits rank ≤10: ticker is among the most discussed by active traders.\n\n"
    "Be direct, data-driven, and brutally honest. "
    "Never hallucinate price data — only use what is provided. "
    "Always return ONLY valid JSON with no markdown, no preamble, no explanation."
)

ANALYSIS_USER_TEMPLATE = """\
Analyze these {n} tickers. Data is sourced from Reddit, StockTwits, Google Trends, \
News RSS, and SEC Form 4. For each ticker, produce a complete analysis object.

TICKER DATA:
{ticker_data}

Return a JSON array of {n} objects. Each object must have EXACTLY these fields:
- ticker: string (the symbol)
- investment_score: integer 1-100 (100 = strongest buy opportunity; factor in \
price momentum, sentiment velocity, volume spike, Google Trends interest, \
insider activity, and risk)
- sentiment_score: integer 1-100 (50 = neutral; >70 strongly bullish; \
<30 strongly bearish; weight all 5 sources)
- sentiment_label: one of ["Strongly Bullish", "Bullish", "Neutral", "Bearish", \
"Strongly Bearish"]
- risk_level: one of ["Low", "Medium", "High", "Extreme"]
- analyst_summary: string, 2-3 sentences of sharp analyst commentary covering \
cross-source momentum, price action, and key consideration
- catalysts: array of 2-4 short strings (what is driving discussion — \
earnings, insider buying, search spike, short squeeze, product news, sector rotation, etc.)
- red_flag: boolean (true if there are manipulation signals, pump-and-dump \
patterns, extremely low market cap with sudden spike, or coordinated hype)
- negative_traction: boolean (true ONLY if the dominant community \
sentiment is bearish — i.e. most posts/comments warn against buying, discuss it \
as a short, or express regret/loss. Do NOT set this based on price decline alone.)
- recommendation: one of ["BUY", "WATCH", "AVOID", "SHORT_WATCH"]

Sort by investment_score descending."""


class AIAnalyzer:
    def __init__(self, api_key: str):
        self.client = Anthropic(api_key=api_key)

    def _build_ticker_summary(
        self,
        agg: AggregatedTicker,
        price: dict,
        supplemental: dict | None = None,
    ) -> str:
        sub_str = ", ".join(f"r/{k}({v})" for k, v in sorted(
            agg.subreddits.items(), key=lambda x: x[1], reverse=True
        ))
        sentiment_direction = (
            "bullish" if agg.avg_sentiment > 0.05
            else "bearish" if agg.avg_sentiment < -0.05
            else "neutral"
        )
        posts_str = " | ".join(p["title"] for p in agg.top_posts[:3]) if agg.top_posts else "N/A"

        lines = [
            f"TICKER: {agg.ticker}",
            # Source 1: Reddit
            f"  [Reddit] Mentions: {agg.total_mentions} "
            f"(posts:{agg.post_mentions} comments:{agg.comment_mentions})",
            f"  [Reddit] Subreddits: {sub_str}",
            f"  [Reddit] VADER Sentiment: {agg.avg_sentiment:.3f} ({sentiment_direction})"
            f" — bullish:{agg.bullish_count} bearish:{agg.bearish_count}"
            f" neutral:{agg.neutral_count}",
            f"  [Reddit] Top Posts: {posts_str}",
        ]
        if price:
            lines += [
                f"  Price: ${price.get('current_price', 'N/A')}",
                f"  1d Change: {price.get('price_change_pct', 'N/A')}%",
                f"  5d Change: {price.get('week_change_pct', 'N/A')}%",
                f"  Volume vs Avg: {price.get('volume_vs_avg', 'N/A')}x",
                f"  Market Cap: {price.get('market_cap', 'N/A')}",
            ]

        if supplemental:
            # Source 2: StockTwits
            st_rank = supplemental.get("stocktwitsRank", 0)
            if st_rank and st_rank > 0:
                lines.append(f"  [StockTwits] Trending Rank: #{st_rank} (1=most trending)")

            # Source 3: Google Trends
            gt_score = supplemental.get("googleTrendsScore", 0)
            if gt_score and gt_score > 0:
                lines.append(f"  [Google Trends] Search Interest: {gt_score}/100 (US, last 7d)")

            # Source 4: News RSS
            news = supplemental.get("newsItems", [])
            if news:
                headlines = " | ".join(
                    f"{n['headline']} ({n.get('source', 'News')})"
                    for n in news[:3]
                )
                lines.append(f"  [News RSS] Recent Headlines: {headlines}")

            # Source 5: SEC Form 4
            insider_count = supplemental.get("insiderTradeCount", 0)
            if insider_count and insider_count > 0:
                lines.append(
                    f"  [SEC Form 4] Insider Trades Filed (last 30d): {insider_count} filings"
                )

        return "\n".join(lines)

    def analyze(
        self,
        tickers: list[AggregatedTicker],
        supplemental_data: dict[str, dict] | None = None,
    ) -> list[TickerAnalysis]:
        """
        Takes top AggregatedTicker list, fetches prices, calls Claude,
        returns list of TickerAnalysis objects.
        """
        if not tickers:
            return []

        # Fetch price data in parallel — each ticker is an independent yfinance call.
        # max_workers capped at 10 to avoid hammering Yahoo Finance.
        price_map: dict[str, dict] = {}
        # Cap at 3 workers — Yahoo Finance rate-limits aggressive parallel requests
        with ThreadPoolExecutor(
            max_workers=min(len(tickers), 3),
            thread_name_prefix="price-fetch",
        ) as pool:
            futures = {
                pool.submit(fetch_price_data, agg.ticker): agg.ticker
                for agg in tickers
            }
            for future in as_completed(futures):
                price_map[futures[future]] = future.result()

        valid_tickers = [agg for agg in tickers if price_map.get(agg.ticker)]
        dropped = len(tickers) - len(valid_tickers)
        if dropped:
            logger.info(f"Dropped {dropped} unrecognized tickers (no Yahoo Finance data)")
        if not valid_tickers:
            logger.warning("No valid tickers after price validation — skipping Claude call")
            return []

        # Market-cap-aware subreddit association:
        # Large caps (≥$10B) require ≥5 mentions in a subreddit to be tagged there —
        # prevents NVDA/AMD/MSFT from appearing under r/pennystocks because one post
        # mentioned them in passing. Small/mid caps keep the ≥2 threshold.
        _LARGE_CAP = 10_000_000_000   # $10B
        for agg in valid_tickers:
            mc = price_map[agg.ticker].get("market_cap_raw", 0)
            min_sub_mentions = 5 if mc >= _LARGE_CAP else 2
            agg.subreddits = {
                k: v for k, v in agg.subreddits.items() if v >= min_sub_mentions
            }
            if mc >= _LARGE_CAP and agg.subreddits != agg.subreddits:
                logger.debug(
                    f"{agg.ticker} (large-cap ${mc/1e9:.0f}B): "
                    f"subreddit breakdown filtered to {agg.subreddits}"
                )

        # Build prompt data (include supplemental multi-source context per ticker)
        ticker_blocks = "\n\n".join(
            self._build_ticker_summary(
                agg,
                price_map[agg.ticker],
                supplemental=(supplemental_data or {}).get(agg.ticker),
            )
            for agg in valid_tickers
        )

        prompt = ANALYSIS_USER_TEMPLATE.format(
            n=len(valid_tickers),
            ticker_data=ticker_blocks,
        )

        logger.info(f"Sending {len(valid_tickers)} tickers to Claude for analysis...")

        response = self.client.messages.create(
            model="claude-haiku-4-5-20251001",
            max_tokens=8192,
            system=[{
                "type": "text",
                "text": ANALYSIS_SYSTEM_PROMPT,
                "cache_control": {"type": "ephemeral"},
            }],
            messages=[{"role": "user", "content": prompt}],
        )

        raw = response.content[0].text.strip()
        # Strip any accidental markdown fences
        raw = raw.replace("```json", "").replace("```", "").strip()

        logger.info("Haiku response length: %d chars, stop_reason: %s", len(raw), response.stop_reason)
        try:
            ai_results: list[dict] = json.loads(raw)
        except json.JSONDecodeError as e:
            logger.error(f"JSON parse failed: {e}\nRaw: {raw[:500]}")
            return []

        # Merge AI results with price data
        results: list[TickerAnalysis] = []
        for ai in ai_results:
            t = ai.get("ticker", "")
            if not t:
                continue
            agg = next((a for a in valid_tickers if a.ticker == t), None)
            price = price_map.get(t, {})

            # Use `or default` instead of dict.get(key, default) so that explicit
            # null values from Claude (which .get() would return as None) are also
            # replaced — preventing JSON null from landing in non-optional Swift fields.
            catalysts_raw = ai.get("catalysts")
            results.append(TickerAnalysis(
                ticker=t,
                company_name=price.get("company_name") or t,
                current_price=float(price.get("current_price") or 0.0),
                price_change_pct=float(price.get("price_change_pct") or 0.0),
                week_change_pct=float(price.get("week_change_pct") or 0.0),
                volume_vs_avg=float(price.get("volume_vs_avg") or 1.0),
                market_cap=price.get("market_cap") or "N/A",
                total_mentions=agg.total_mentions if agg else 0,
                subreddit_breakdown=agg.subreddits if agg else {},
                avg_sentiment_raw=agg.avg_sentiment if agg else 0.0,
                bullish_count=agg.bullish_count if agg else 0,
                bearish_count=agg.bearish_count if agg else 0,
                neutral_count=agg.neutral_count if agg else 0,
                top_posts=agg.top_posts if agg else [],
                investment_score=int(ai.get("investment_score") or 50),
                sentiment_score=int(ai.get("sentiment_score") or 50),
                sentiment_label=ai.get("sentiment_label") or "Neutral",
                risk_level=ai.get("risk_level") or "Medium",
                analyst_summary=ai.get("analyst_summary") or "",
                catalysts=catalysts_raw if isinstance(catalysts_raw, list) else [],
                red_flag=bool(ai.get("red_flag")),
                negative_traction=bool(ai.get("negative_traction")),
                recommendation=ai.get("recommendation") or "WATCH",
            ))

        logger.info(f"Claude returned {len(results)} analyses")
        return results
