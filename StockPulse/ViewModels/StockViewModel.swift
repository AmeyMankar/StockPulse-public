// StockViewModel.swift
// StockPulse — Main observable view model

import Foundation
import Combine
import SwiftUI

// MARK: - App-level error model

/// Classifies errors so the UI can show the right message and action.
enum AppError: LocalizedError {
    case offline                  // device has no network
    case serverUnavailable        // backend is down / unreachable
    case noDataYet                // server started but first scan hasn't finished
    case transient(String)        // any other recoverable error

    var errorDescription: String? {
        switch self {
        case .offline:
            return "No internet connection. Check your network and try again."
        case .serverUnavailable:
            return "Server is temporarily unavailable. We'll retry automatically."
        case .noDataYet:
            return "Waiting for the first scan to complete — check back in a minute."
        case .transient(let msg):
            return msg
        }
    }

    var isRetryable: Bool {
        switch self {
        case .noDataYet: return false
        default:         return true
        }
    }
}

@MainActor
final class StockViewModel: ObservableObject {

    // MARK: - Published State
    @Published var allTickers: [TickerAnalysis] = []
    @Published var isLoading = false
    @Published var appError: AppError?          // nil = no current error
    @Published var showError = false
    @Published var lastUpdated: Date?
    @Published var rawTickerCount = 0
    private var lastScanTimestamp: String?
    @Published var selectedFilter: TickerFilter = .all
    @Published var selectedSort: TickerSort = .investmentScore
    @Published var selectedSubreddit: String = "All"
    @Published var searchQuery: String = ""
    @Published var selectedTicker: TickerAnalysis?
    @Published var watchlist: [String] = []      // ordered ticker symbols
    @Published var countdown: Int = 900         // seconds until next scan
    @Published var isServerOnline = false

    // Convenience accessor for views that only need a string
    var errorMessage: String? { appError?.errorDescription }

    // MARK: - Watchlist Computed

    /// Watchlisted tickers that appear in the current scan (have live data)
    var watchlistTickers: [TickerAnalysis] {
        watchlist.compactMap { sym in allTickers.first { $0.ticker == sym } }
    }

    func isInWatchlist(_ ticker: String) -> Bool {
        watchlist.contains(ticker.uppercased())
    }

    @Published var showPaywall = false

    func addToWatchlist(_ ticker: String) {
        let sym = ticker.uppercased()
        guard !watchlist.contains(sym) else { return }
        if !PurchaseService.shared.isPremium && watchlist.count >= PurchaseService.freeWatchlistLimit {
            showPaywall = true
            return
        }
        watchlist.append(sym)
        saveWatchlist()
        syncWatchlistWithBackend()
        Analytics.capture("watchlist_ticker_added", ["ticker": sym])
        // If the ticker is already in the current scan, notify immediately
        if let analysis = allTickers.first(where: { $0.ticker == sym }) {
            let topPost = analysis.safeRedditPosts.first?.title
            let body = "\(analysis.sentimentLabel) · Score \(analysis.investmentScore)" + (topPost.map { " · \($0)" } ?? "")
            notifications.scheduleWatchlistAlert(ticker: sym, postTitle: body)
        }
    }

    func removeFromWatchlist(_ ticker: String) {
        let sym = ticker.uppercased()
        watchlist.removeAll { $0 == sym }
        saveWatchlist()
        syncWatchlistWithBackend()
        Analytics.capture("watchlist_ticker_removed", ["ticker": sym])
    }

    func moveWatchlistItems(from: IndexSet, to: Int) {
        watchlist.move(fromOffsets: from, toOffset: to)
        saveWatchlist()
    }

    func saveWatchlist() {
        UserDefaults.standard.set(watchlist, forKey: "watchlist")
    }

    private func loadWatchlist() {
        watchlist = UserDefaults.standard.stringArray(forKey: "watchlist") ?? []
    }

    func syncWatchlistWithBackend() {
        guard let token = NotificationService.shared.deviceToken else { return }
        Task { try? await api.updateWatchlist(token: token, tickers: watchlist) }
    }

    // MARK: - Computed Views
    var positiveTickers: [TickerAnalysis] { allTickers.filter { !$0.negativeTraction } }
    var negativeTickers: [TickerAnalysis] { allTickers.filter { $0.negativeTraction } }
    var redFlagTickers:  [TickerAnalysis] { allTickers.filter { $0.redFlag } }

    var filteredTickers: [TickerAnalysis] {
        var base = allTickers

        // Subreddit filter
        if selectedSubreddit != "All" {
            let sub = selectedSubreddit.replacingOccurrences(of: "r/", with: "")
            base = base.filter { $0.subredditBreakdown[sub] != nil }
        }

        // Category filter
        switch selectedFilter {
        case .all:        break
        case .bullish:    base = base.filter { !$0.negativeTraction }
        case .bearish:    base = base.filter { $0.negativeTraction }
        case .redFlags:   base = base.filter { $0.redFlag }
        case .highVolume: base = base.filter { $0.volumeVsAvg >= 1.3 }
        }

        // Search
        if !searchQuery.isEmpty {
            let q = searchQuery.uppercased()
            base = base.filter {
                $0.ticker.contains(q) || $0.companyName.uppercased().contains(q)
            }
        }

        // Sort
        switch selectedSort {
        case .investmentScore: base.sort { $0.investmentScore > $1.investmentScore }
        case .sentimentScore:  base.sort { $0.sentimentScore > $1.sentimentScore }
        case .mentions:        base.sort { $0.totalMentions > $1.totalMentions }
        case .priceChange:     base.sort { $0.priceChangePct > $1.priceChangePct }
        case .riskLevel:
            let order = ["Low": 0, "Medium": 1, "High": 2, "Extreme": 3]
            base.sort { (order[$0.riskLevel] ?? 1) < (order[$1.riskLevel] ?? 1) }
        }

        return base
    }

    var countdownFormatted: String {
        let h = countdown / 3600
        let m = (countdown % 3600) / 60
        let s = countdown % 60
        if h > 0 {
            return String(format: "%d:%02d:%02d", h, m, s)
        }
        return String(format: "%02d:%02d", m, s)
    }

    var availableSubreddits: [String] {
        var subs = Set<String>()
        allTickers.forEach { $0.subredditBreakdown.keys.forEach { subs.insert("r/\($0)") } }
        return ["All"] + subs.sorted()
    }

    // MARK: - Private
    private var countdownTimer: Timer?
    private var autoRefreshTimer: Timer?
    private let api = APIService.shared
    private let notifications = NotificationService.shared
    // Suppress watchlist alerts on first fetch — they'd all fire as "new" since
    // lastScanTimestamp starts nil every session.
    private var isInitialLoad = true

    // MARK: - Init
    init() {
        loadWatchlist()
        resetCountdown()
        startCountdown()
        Task { await checkServerHealth() }
        Task { await fetchData() }
        // Listen for notification taps
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleNotificationTap(_:)),
            name: .didTapScanNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleWatchlistNotificationTap(_:)),
            name: .didTapWatchlistNotification,
            object: nil
        )
    }

    // MARK: - Data Fetching

    func fetchData() async {
        // Prevent overlapping fetches (e.g. pull-to-refresh fires while timer auto-refresh runs)
        guard !isLoading else { return }
        isLoading = true
        appError = nil

        do {
            let scan = try await api.fetchLatestScan()
            // isInitialLoad guards against firing alerts on app open — lastScanTimestamp
            // is nil every session so every first fetch would appear "new" without this flag.
            let isNewScan = !isInitialLoad && scan.timestamp != lastScanTimestamp && !scan.timestamp.isEmpty
            allTickers = scan.results
            lastUpdated = Date()
            lastScanTimestamp = scan.timestamp
            rawTickerCount = scan.rawTickerCount
            isInitialLoad = false
            resetCountdown()
            CrashReporter.shared.breadcrumb("fetchData success — \(scan.results.count) tickers")

            // Fire watchlist alerts only when a genuinely new scan arrived mid-session
            if isNewScan {
                let watchlistHits = scan.results.filter { watchlist.contains($0.ticker) }
                for ticker in watchlistHits {
                    let topPost = ticker.safeRedditPosts.first?.title
                    let sentiment = ticker.sentimentLabel
                    let score = ticker.investmentScore
                    let body = "\(sentiment) · Score \(score)" + (topPost.map { " · \($0)" } ?? "")
                    notifications.scheduleWatchlistAlert(ticker: ticker.ticker, postTitle: body)
                }
            }
        } catch let e as APIError {
            let mapped = mapAPIError(e)
            appError = mapped
            showError = true
            // Only report unexpected errors — offline/timeout are user-environment issues
            if case .transient = mapped {
                CrashReporter.shared.capture(error: e, context: ["source": "fetchData"])
            }
        } catch is CancellationError {
            // Task was cancelled (view disappeared or app backgrounded) — not a real error
            isLoading = false
            return
        } catch {
            appError = .transient(error.localizedDescription)
            showError = true
            CrashReporter.shared.capture(error: error, context: ["source": "fetchData"])
        }

        isLoading = false
    }

    func refresh() {
        Task { await fetchData() }
    }

    func triggerManualScan() {
        Task {
            isLoading = true
            do {
                let previousTimestamp = lastScanTimestamp
                try await api.triggerScan()
                CrashReporter.shared.breadcrumb("Manual scan triggered")
                // Poll every 10 s for up to 5 minutes waiting for a new scan timestamp
                for _ in 0..<30 {
                    try await Task.sleep(nanoseconds: 10_000_000_000)
                    let scan = try await api.fetchLatestScan()
                    if scan.timestamp != previousTimestamp {
                        allTickers = scan.results
                        lastUpdated = Date()
                        lastScanTimestamp = scan.timestamp
                        rawTickerCount = scan.rawTickerCount
                        resetCountdown()
                        isLoading = false
                        return
                    }
                }
                // Timed out — surface whatever the server has now
                await fetchData()
            } catch is CancellationError {
                isLoading = false
            } catch let e as APIError {
                appError = mapAPIError(e)
                showError = true
                isLoading = false
            } catch {
                appError = .transient("Scan trigger failed: \(error.localizedDescription)")
                showError = true
                isLoading = false
                CrashReporter.shared.capture(error: error, context: ["source": "triggerManualScan"])
            }
        }
    }

    func checkServerHealth() async {
        do {
            isServerOnline = try await api.healthCheck()
        } catch {
            isServerOnline = false
        }
    }

    // MARK: - Error Mapping

    /// Converts an APIError into an AppError with user-friendly copy.
    private func mapAPIError(_ error: APIError) -> AppError {
        switch error {
        case .offline:
            return .offline
        case .timeout, .networkError:
            return .serverUnavailable
        case .serverError(503, _), .serverError(502, _), .serverError(504, _):
            return .serverUnavailable
        case .serverError(503, let msg) where msg.contains("No scan completed"):
            return .noDataYet
        default:
            return .transient(error.localizedDescription)
        }
    }

    // MARK: - Countdown Timer

    private func startCountdown() {
        countdownTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor [weak self] in
                guard let self else { return }
                if self.countdown > 0 {
                    self.countdown -= 1
                } else {
                    await self.fetchData()
                }
            }
        }
    }

    private func resetCountdown() {
        // Sync with cron schedule: runs every 15 minutes at :00, :15, :30, :45
        let now = Date()
        let cal = Calendar.current
        let minute = cal.component(.minute, from: now)
        let second = cal.component(.second, from: now)
        let secondsIntoCurrentQuarter = (minute % 15) * 60 + second
        countdown = max(1, 900 - secondsIntoCurrentQuarter)
    }

    func stopTimers() {
        countdownTimer?.invalidate()
        autoRefreshTimer?.invalidate()
    }

    // MARK: - Notification Handling

    @objc private func handleNotificationTap(_ notification: Foundation.Notification) {
        guard let ticker = notification.userInfo?["ticker"] as? String else { return }
        selectedTicker = allTickers.first { $0.ticker == ticker }
    }

    @objc private func handleWatchlistNotificationTap(_ notification: Foundation.Notification) {
        // Signal ContentView to switch to the Watchlist tab
        NotificationCenter.default.post(name: .switchToWatchlistTab, object: nil)
    }
}
