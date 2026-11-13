# StockPulse AI

StockPulse AI is an iPhone app that shows which stocks retail investors are talking about right now. It reads public discussion from investing subreddits and other public sources, counts ticker mentions, measures sentiment, and shows a short AI-written summary per ticker.

This repository contains the iOS app (SwiftUI) and the backend that powers it (Python / FastAPI).

> StockPulse is an information tool, not investment advice. See the in-app disclaimer and `docs/terms.html`.

## How it works

```
 public sources ──► scan worker ──► Claude summaries ──► backend API ──► iOS app
 (Reddit, StockTwits,    (every 15 min)                     (FastAPI)       (SwiftUI, push alerts)
  news RSS, Google Trends,
  SEC Form 4 filings)
```

1. A scheduled worker (`backend/scan_worker.py`) collects data from public sources.
2. Tickers are extracted and sentiment is scored. Slow-moving sources (Google Trends, SEC filings) are cached for hours.
3. The Claude API writes a short per-ticker summary from the collected data.
4. The worker posts the result to the backend, which serves it to the app and sends push notifications for tickers on a user's watchlist.

## Reddit usage

Reddit is one of five sources. It is used in a deliberately narrow way:

- **Read-only.** The app never posts, comments, votes, messages, or moderates, and it uses no user accounts or user data.
- **Public content only,** from the hot listings of 9 subreddits: r/wallstreetbets, r/stocks, r/pennystocks, r/stockstobuytoday, r/stockmarket, r/investing, r/options, r/Daytrading, r/smallcapstocks.
- **Small volume:** up to 10 posts per subreddit and up to 30 comments per post, once every 15 minutes, with a global limit of one request per second.
- **Purpose:** counting ticker mentions and measuring sentiment. Reddit text is not republished in the app.
- **Attribution:** for each ticker the app shows up to five post titles with their score and a link back to the original thread on Reddit.
- **AI use:** aggregated results are sent to the Anthropic API to generate summaries. Reddit content is not used to train models.
- **Retention:** only the latest scan result is kept.
- **Status:** the current reader (`backend/reddit_scraper.py`) fetches public pages and is being migrated to Reddit's official Data API. Access has been requested, and this repository will be updated when it is in place.

## Repository layout

| Path | What it is |
|---|---|
| `StockPulse/` | iOS app source (SwiftUI, StoreKit, APNs) |
| `StockPulse.xcodeproj/` | Xcode project |
| `backend/` | FastAPI server, scan worker, scrapers, Claude analysis, push notifications |
| `docs/` | Source for the public landing, support, privacy, and terms pages |
| `codemagic.yaml` | CI build and TestFlight upload |
| `railway.toml` | Backend deployment configuration |

## Running it yourself

### Backend
```bash
cd backend
python3 -m venv venv && source venv/bin/activate
pip install -r requirements.txt
cp .env.example .env      # then fill in your own keys
uvicorn main:app --reload
```
See `backend/.env.example` for the variables. You need your own Anthropic API key. The app-facing key (`CLIENT_API_KEY`) and the worker-only key (`INGEST_API_KEY`) are separate on purpose.

### iOS app
```bash
cp Secrets.xcconfig.example Secrets.xcconfig   # then set your own CLIENT_API_KEY
```
Open `StockPulse.xcodeproj` in Xcode. `Secrets.xcconfig` is gitignored and is read into `Info.plist` at build time. You will also need to set the backend URL in `StockPulse/Services/APIService.swift` to your own server and use your own signing team and bundle ID.

## Privacy

The app does not collect names, emails, or financial information. See [`docs/privacy.html`](docs/privacy.html).

## License

The source is published for transparency and review. No license is granted for reuse or redistribution.
