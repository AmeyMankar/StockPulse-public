"""
locustfile.py
-------------
StockPulse API load test — simulates realistic iOS app traffic.

Scenarios modelled:
  - AppUser (90 % of users): typical read pattern — fetch scan on open,
    poll on countdown, check a single ticker detail.
  - HeavyUser (10 % of users): power user — rapid poll, all endpoints,
    frequent ticker lookups.

Run headless (recommended for CI):
    locust -f locustfile.py --headless \
           -u 100 -r 10 --run-time 60s \
           --host http://localhost:8000 \
           --csv results/load_test

Run with live web UI:
    locust -f locustfile.py --host http://localhost:8000
    # then open http://localhost:8089
"""

import os
import random
from pathlib import Path

from dotenv import load_dotenv
from locust import HttpUser, task, between, constant_pacing, events
from locust.env import Environment

# ── Config ────────────────────────────────────────────────────────────────────
# All endpoints exercised below are public reads (no auth required), but the
# header is included in case authenticated endpoints get added to the test later.
load_dotenv(Path(__file__).parent / ".env", override=True)
HEADERS = {"X-API-Key": os.getenv("CLIENT_API_KEY", "")}

# Tickers likely to be in the latest scan — fallback if /scan/latest unavailable
KNOWN_TICKERS = ["MSFT", "NVDA", "GOOGL", "AMD", "MU", "RKLB", "ASTS", "GCTS"]


# ── Typical iOS App User ───────────────────────────────────────────────────────
class AppUser(HttpUser):
    """
    Represents 90 % of real users.
    Pattern: open app → load scan → occasionally tap a ticker → wait.
    """
    weight = 9
    wait_time = between(2, 8)  # realistic think-time between requests

    def on_start(self):
        """Called once per simulated user at startup — mirrors app launch."""
        self.client.get("/health", name="/health")
        resp = self.client.get(
            "/scan/latest",
            headers=HEADERS,
            name="/scan/latest",
        )
        self._tickers = []
        if resp.status_code == 200:
            data = resp.json()
            self._tickers = [t["ticker"] for t in data.get("results", [])]
        if not self._tickers:
            self._tickers = KNOWN_TICKERS

    @task(5)
    def fetch_latest_scan(self):
        """Most common action — app polls /scan/latest on countdown expiry."""
        self.client.get("/scan/latest", headers=HEADERS, name="/scan/latest")

    @task(3)
    def fetch_top_tickers(self):
        """App home screen also calls /scan/top for ranked list."""
        self.client.get(
            "/scan/top?limit=10",
            headers=HEADERS,
            name="/scan/top",
        )

    @task(2)
    def fetch_ticker_detail(self):
        """User taps a ticker card to see detail."""
        ticker = random.choice(self._tickers)
        self.client.get(
            f"/ticker/{ticker}",
            headers=HEADERS,
            name="/ticker/{symbol}",
        )

    @task(1)
    def fetch_schedule(self):
        """Settings screen loads scan schedule."""
        self.client.get(
            "/scan/schedule",
            headers=HEADERS,
            name="/scan/schedule",
        )

    @task(1)
    def health_check(self):
        """App checks server connectivity on foreground resume."""
        self.client.get("/health", name="/health")


# ── Power / Heavy User ────────────────────────────────────────────────────────
class HeavyUser(HttpUser):
    """
    Represents 10 % of users who refresh aggressively or use background fetch.
    """
    weight = 1
    wait_time = between(0.5, 2)  # much faster polling

    def on_start(self):
        self._tickers = KNOWN_TICKERS

    @task(6)
    def rapid_scan_poll(self):
        self.client.get("/scan/latest", headers=HEADERS, name="/scan/latest")

    @task(3)
    def rapid_ticker_lookup(self):
        ticker = random.choice(self._tickers)
        self.client.get(
            f"/ticker/{ticker}",
            headers=HEADERS,
            name="/ticker/{symbol}",
        )

    @task(2)
    def negative_tickers(self):
        self.client.get("/scan/negative", headers=HEADERS, name="/scan/negative")

    @task(1)
    def top_exclude_negative(self):
        self.client.get(
            "/scan/top?limit=10&exclude_negative=true",
            headers=HEADERS,
            name="/scan/top?exclude_negative",
        )


# ── Custom event hooks for summary reporting ──────────────────────────────────
@events.quitting.add_listener
def print_summary(environment: Environment, **_kwargs):
    stats = environment.runner.stats
    total = stats.total

    print("\n" + "=" * 60)
    print("  STOCKPULSE LOAD TEST SUMMARY")
    print("=" * 60)
    print(f"  Total requests  : {total.num_requests:,}")
    print(f"  Failures        : {total.num_failures:,}  "
          f"({total.fail_ratio * 100:.1f}%)")
    print(f"  Avg latency     : {total.avg_response_time:.0f} ms")
    print(f"  Median latency  : {total.get_response_time_percentile(0.5):.0f} ms")
    print(f"  95th pct        : {total.get_response_time_percentile(0.95):.0f} ms")
    print(f"  99th pct        : {total.get_response_time_percentile(0.99):.0f} ms")
    print(f"  Peak RPS        : {total.current_rps:.1f}")
    print(f"  Max response    : {total.max_response_time:.0f} ms")
    print("=" * 60)

    # Fail the test if SLAs are violated
    p95 = total.get_response_time_percentile(0.95)
    fail_ratio = total.fail_ratio
    sla_ok = True

    if fail_ratio > 0.01:
        print(f"\n  ❌ SLA VIOLATION: failure rate {fail_ratio*100:.1f}% > 1%")
        sla_ok = False
    else:
        print(f"\n  ✅ Failure rate OK: {fail_ratio*100:.2f}% ≤ 1%")

    if p95 > 500:
        print(f"  ❌ SLA VIOLATION: p95 latency {p95:.0f}ms > 500ms")
        sla_ok = False
    else:
        print(f"  ✅ p95 latency OK: {p95:.0f}ms ≤ 500ms")

    if sla_ok:
        print("\n  ✅ ALL SLAs PASSED")
    else:
        print("\n  ❌ SLA VIOLATIONS — see above")
        environment.process_exit_code = 1

    print("=" * 60 + "\n")
