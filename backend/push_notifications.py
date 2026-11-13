"""
push_notifications.py
---------------------
Sends iOS push notifications via Apple Push Notification service (APNs)
using HTTP/2 and JWT authentication.
"""

import time
import asyncio
import logging
import httpx
import jwt  # pip install PyJWT
from pathlib import Path
from dataclasses import dataclass
from ai_analyzer import TickerAnalysis

logger = logging.getLogger(__name__)

APNS_HOST_PROD = "https://api.push.apple.com"
APNS_HOST_DEV = "https://api.sandbox.push.apple.com"


@dataclass
class DeviceToken:
    token: str
    sandbox: bool = True   # True for development, False for production


class APNsPusher:
    def __init__(
        self,
        key_id: str,
        team_id: str,
        bundle_id: str,
        key_path: str,
        sandbox: bool = True,
    ):
        self.key_id = key_id
        self.team_id = team_id
        self.bundle_id = bundle_id
        self.key_path = key_path
        self.sandbox = sandbox
        self._token_cache: tuple[str, float] | None = None  # (jwt_token, issued_at)
        self._load_key()

    def _load_key(self):
        path = Path(self.key_path)
        if not path.exists():
            raise FileNotFoundError(f"APNs key not found: {self.key_path}")
        self._private_key = path.read_text()
        logger.info(f"APNs key loaded: {self.key_path}")

    def _get_jwt(self) -> str:
        """Generate (or reuse cached) JWT for APNs auth. Tokens expire after 1 hour."""
        now = time.time()
        if self._token_cache and (now - self._token_cache[1]) < 3000:
            return self._token_cache[0]

        token = jwt.encode(
            payload={"iss": self.team_id, "iat": int(now)},
            key=self._private_key,
            algorithm="ES256",
            headers={"kid": self.key_id},
        )
        self._token_cache = (token, now)
        logger.debug("New APNs JWT generated")
        return token

    def _build_payload(
        self,
        title: str,
        body: str,
        data: dict | None = None,
        badge: int | None = None,
        sound: str = "default",
    ) -> dict:
        alert = {"title": title, "body": body}
        aps: dict = {"alert": alert, "sound": sound}
        if badge is not None:
            aps["badge"] = badge

        payload = {"aps": aps}
        if data:
            payload.update(data)
        return payload

    def send(
        self,
        device_token: str,
        title: str,
        body: str,
        data: dict | None = None,
        badge: int | None = None,
        priority: int = 10,           # 10 = immediate, 5 = conserve power
        push_type: str = "alert",
    ) -> str:
        """
        Send a push notification.

        Returns:
            "ok"      — delivered successfully
            "expired" — token no longer valid (app uninstalled / re-registered);
                        caller should prune this token from the device list
            "error"   — transient failure (network issue, APNs server error, etc.)
        """
        host = APNS_HOST_DEV if self.sandbox else APNS_HOST_PROD
        url = f"{host}/3/device/{device_token}"
        payload = self._build_payload(title, body, data, badge)

        headers = {
            "authorization": f"bearer {self._get_jwt()}",
            "apns-topic": self.bundle_id,
            "apns-push-type": push_type,
            "apns-priority": str(priority),
            "content-type": "application/json",
        }

        try:
            with httpx.Client(http2=True) as client:
                resp = client.post(url, json=payload, headers=headers, timeout=10.0)

            if resp.status_code == 200:
                logger.info(f"Push sent to {device_token[:12]}...")
                return "ok"

            # 410 = device token is no longer active (app uninstalled / OS revoked)
            if resp.status_code == 410:
                logger.warning(f"APNs 410 — expired token: {device_token[:12]}...")
                return "expired"

            # 400 + BadDeviceToken = malformed or invalidated token
            try:
                reason = resp.json().get("reason", "")
            except Exception:
                reason = resp.text[:80]
            if resp.status_code == 400 and reason == "BadDeviceToken":
                logger.warning(f"APNs BadDeviceToken — expired token: {device_token[:12]}...")
                return "expired"

            logger.error(
                f"APNs {resp.status_code} ({reason}) for {device_token[:12]}..."
            )
            return "error"
        except Exception as e:
            logger.error(f"Push send failed for {device_token[:12]}...: {e}")
            return "error"

    def send_scan_alert(
        self,
        device_token: str,
        analyses: list[TickerAnalysis],
        badge: int | None = None,
    ) -> str:
        """
        Send the Reddit scan summary notification.
        Returns "ok", "expired", or "error" (see send() docstring).
        """
        if not analyses:
            return "error"

        top = analyses[0]
        bearish = [a for a in analyses if a.negative_traction]
        bullish = [a for a in analyses if not a.negative_traction]

        title = f"📡 Reddit Scan — {len(analyses)} Tickers"

        body_parts = [f"🚀 #{1} {top.ticker} (Score {top.investment_score})"]
        if len(bullish) > 1:
            next_picks = ", ".join(f"${a.ticker}" for a in bullish[1:4])
            body_parts.append(f"Also trending: {next_picks}")
        if bearish:
            bearish_tickers = ", ".join(f"${a.ticker}" for a in bearish[:3])
            body_parts.append(f"⚠ {len(bearish)} bearish: {bearish_tickers}")

        body = " · ".join(body_parts)

        custom_data = {
            "scan_type": "15min",
            "top_ticker": top.ticker,
            "top_score": top.investment_score,
            "bearish_count": len(bearish),
            "bullish_count": len(bullish),
        }

        return self.send(
            device_token=device_token,
            title=title,
            body=body,
            data=custom_data,
            badge=badge,
        )

    def send_watchlist_alert(
        self,
        device_token: str,
        ticker: str,
        post_title: str | None = None,
        investment_score: int | None = None,
    ) -> str:
        """Send a targeted alert when a watched ticker enters the trending list."""
        title = f"🔥 ${ticker} is now trending on Reddit"
        body = (
            post_title
            or f"${ticker} has new Reddit activity — check your Watchlist"
        )
        data: dict = {"type": "watchlist_alert", "ticker": ticker}
        if investment_score is not None:
            data["investment_score"] = investment_score
        return self.send(device_token=device_token, title=title, body=body, data=data)

    def send_to_all(
        self,
        device_tokens: list[str],
        analyses: list[TickerAnalysis],
    ) -> dict[str, str]:
        """
        Send scan alert to all registered devices (synchronous, sequential).
        Kept for backward compatibility — prefer send_to_all_async for production.
        """
        results: dict[str, str] = {}
        for token in device_tokens:
            results[token] = self.send_scan_alert(
                device_token=token,
                analyses=analyses,
                badge=len([a for a in analyses if not a.negative_traction]),
            )
        return results

    # ── Async batch methods ───────────────────────────────────────────────────

    async def send_async(
        self,
        client: httpx.AsyncClient,
        semaphore: asyncio.Semaphore,
        device_token: str,
        title: str,
        body: str,
        data: dict | None = None,
        badge: int | None = None,
        priority: int = 10,
        push_type: str = "alert",
    ) -> str:
        """Async version of send() — shares a single httpx client across the batch."""
        host = APNS_HOST_DEV if self.sandbox else APNS_HOST_PROD
        url = f"{host}/3/device/{device_token}"
        payload = self._build_payload(title, body, data, badge)
        headers = {
            "authorization": f"bearer {self._get_jwt()}",
            "apns-topic": self.bundle_id,
            "apns-push-type": push_type,
            "apns-priority": str(priority),
            "content-type": "application/json",
        }
        async with semaphore:
            try:
                resp = await client.post(url, json=payload, headers=headers, timeout=10.0)
                if resp.status_code == 200:
                    return "ok"
                if resp.status_code == 410:
                    logger.warning("APNs 410 — expired token: %s...", device_token[:12])
                    return "expired"
                try:
                    reason = resp.json().get("reason", "")
                except Exception:
                    reason = resp.text[:80]
                if resp.status_code == 400 and reason == "BadDeviceToken":
                    logger.warning("APNs BadDeviceToken — expired: %s...", device_token[:12])
                    return "expired"
                logger.error("APNs %d (%s) for %s...", resp.status_code, reason, device_token[:12])
                return "error"
            except Exception as e:
                logger.error("Push send failed for %s...: %s", device_token[:12], e)
                return "error"

    async def send_to_all_async(
        self,
        device_tokens: list[str],
        analyses: list[TickerAnalysis],
        max_concurrent: int = 50,
    ) -> dict[str, str]:
        """
        Send scan alert to all devices concurrently.
        Caps at max_concurrent simultaneous APNs connections to avoid overwhelming Apple.
        Returns {token: "ok"|"expired"|"error"}.
        """
        if not device_tokens:
            return {}

        badge = len([a for a in analyses if not a.negative_traction])
        top = analyses[0] if analyses else None
        bearish = [a for a in analyses if a.negative_traction]
        bullish = [a for a in analyses if not a.negative_traction]

        title = f"📡 Reddit Scan — {len(analyses)} Tickers"
        body_parts = [f"🚀 #{1} {top.ticker} (Score {top.investment_score})"] if top else []
        if len(bullish) > 1:
            body_parts.append("Also trending: " + ", ".join(f"${a.ticker}" for a in bullish[1:4]))
        if bearish:
            body_parts.append(f"⚠ {len(bearish)} bearish: " + ", ".join(f"${a.ticker}" for a in bearish[:3]))
        body = " · ".join(body_parts)

        custom_data = {
            "scan_type": "15min",
            "top_ticker": top.ticker if top else "",
            "top_score": top.investment_score if top else 0,
            "bearish_count": len(bearish),
            "bullish_count": len(bullish),
        }

        semaphore = asyncio.Semaphore(max_concurrent)
        async with httpx.AsyncClient(http2=True) as client:
            tasks = [
                self.send_async(client, semaphore, token, title, body, custom_data, badge)
                for token in device_tokens
            ]
            results_list = await asyncio.gather(*tasks, return_exceptions=True)

        return {
            token: (r if isinstance(r, str) else "error")
            for token, r in zip(device_tokens, results_list)
        }

    async def send_watchlist_alert_async(
        self,
        client: httpx.AsyncClient,
        semaphore: asyncio.Semaphore,
        device_token: str,
        ticker: str,
        post_title: str | None = None,
        investment_score: int | None = None,
    ) -> tuple[str, str]:
        """Returns (device_token, result) so callers can identify expired tokens."""
        title = f"🔥 ${ticker} is now trending on Reddit"
        body = post_title or f"${ticker} has new Reddit activity — check your Watchlist"
        data: dict = {"type": "watchlist_alert", "ticker": ticker}
        if investment_score is not None:
            data["investment_score"] = investment_score
        result = await self.send_async(client, semaphore, device_token, title, body, data)
        return device_token, result
