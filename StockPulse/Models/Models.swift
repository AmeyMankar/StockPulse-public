// Models.swift
// StockPulse — Data models matching the backend API response

import Foundation

// MARK: - Reddit Post (linked from ticker card)

struct RedditPost: Codable, Identifiable {
    var id: String { url }
    let title: String
    let url: String
    let score: Int
}

// MARK: - News Item (from Yahoo Finance RSS and other feeds)

struct NewsItem: Codable, Identifiable {
    var id: String { url.isEmpty ? headline : url }
    let headline: String
    let source: String      // e.g. "Yahoo Finance", "Reuters", "MarketWatch"
    let url: String
    let publishedAt: String // RFC 2822 / ISO 8601 string from feed

    var timeAgo: String {
        // Try RFC 2822 first (common in RSS), then ISO 8601
        let rfc = DateFormatter()
        rfc.locale = Locale(identifier: "en_US_POSIX")
        rfc.dateFormat = "EEE, dd MMM yyyy HH:mm:ss Z"
        var date = rfc.date(from: publishedAt)
        if date == nil {
            let iso = ISO8601DateFormatter()
            iso.formatOptions = [.withInternetDateTime]
            date = iso.date(from: publishedAt)
        }
        guard let date else { return "" }
        let secs = Int(-date.timeIntervalSinceNow)
        if secs < 60    { return "\(secs)s ago" }
        if secs < 3600  { return "\(secs / 60)m ago" }
        if secs < 86400 { return "\(secs / 3600)h ago" }
        return "\(secs / 86400)d ago"
    }
}

// MARK: - StockTwits Message

struct StockTwitsMessage: Codable, Identifiable {
    var id: String { "\(stId)" }
    let stId: Int
    let body: String
    let createdAt: String
    let username: String
    let likes: Int
    let sentiment: String?   // "Bullish", "Bearish", or nil

    var messageURL: URL? {
        URL(string: "https://stocktwits.com/\(username)/message/\(stId)")
    }

    var timeAgo: String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        var date = formatter.date(from: createdAt)
        if date == nil {
            formatter.formatOptions = [.withInternetDateTime]
            date = formatter.date(from: createdAt)
        }
        guard let date else { return "" }
        let secs = Int(-date.timeIntervalSinceNow)
        if secs < 60   { return "\(secs)s ago" }
        if secs < 3600 { return "\(secs / 60)m ago" }
        if secs < 86400 { return "\(secs / 3600)h ago" }
        return "\(secs / 86400)d ago"
    }
}

// MARK: - Core Ticker Analysis Model

struct TickerAnalysis: Codable, Identifiable {
    var id: String { ticker }

    let ticker: String
    let companyName: String
    let currentPrice: Double
    let priceChangePct: Double
    let weekChangePct: Double
    let volumeVsAvg: Double
    let marketCap: String
    let totalMentions: Int
    let subredditBreakdown: [String: Int]
    let avgSentimentRaw: Double
    let bullishCount: Int
    let bearishCount: Int
    let neutralCount: Int
    let topPosts: [String]               // backward-compat: titles only
    let redditPosts: [RedditPost]?       // new: full {title, url, score} objects
    var safeRedditPosts: [RedditPost] { redditPosts ?? [] }
    let investmentScore: Int
    let sentimentScore: Int
    let sentimentLabel: String
    let riskLevel: String
    let analystSummary: String
    let catalysts: [String]
    let redFlag: Bool
    let negativeTraction: Bool
    let recommendation: String
    // Source 2: StockTwits
    let stocktwitsRank: Int?
    let stocktwitsMessages: [StockTwitsMessage]?
    var safeStockTwitsMessages: [StockTwitsMessage] { stocktwitsMessages ?? [] }

    // Source 3: Google Trends
    let googleTrendsScore: Int?         // 0-100, US, last 7 days

    // Source 4: News RSS
    let newsItems: [NewsItem]?
    var safeNewsItems: [NewsItem] { newsItems ?? [] }

    // Source 5: SEC Form 4
    let insiderTradeCount: Int?         // Form 4 filings in last 30 days
    let insiderTradeUrl: String?        // link to EDGAR for this ticker

    // MARK: Computed helpers

    var isPositive: Bool { priceChangePct >= 0 }
    var priceChangeFormatted: String {
        let sign = priceChangePct >= 0 ? "+" : ""
        return "\(sign)\(String(format: "%.1f", priceChangePct))%"
    }
    var weekChangeFormatted: String {
        let sign = weekChangePct >= 0 ? "+" : ""
        return "\(sign)\(String(format: "%.1f", weekChangePct))%"
    }
    var volumeFormatted: String {
        "\(String(format: "%.1f", volumeVsAvg))x vol"
    }
    var sentimentLabelShort: String {
        switch sentimentLabel {
        case "Strongly Bullish": return "STRONG BULL"
        case "Strongly Bearish": return "STRONG BEAR"
        default: return sentimentLabel.uppercased()
        }
    }
    var recommendationColor: String {
        switch recommendation {
        case "BUY": return "green"
        case "WATCH": return "yellow"
        case "AVOID": return "red"
        case "SHORT_WATCH": return "orange"
        default: return "gray"
        }
    }
    var topSubreddit: String {
        subredditBreakdown.max(by: { $0.value < $1.value })?.key ?? "unknown"
    }
}

// MARK: - Scan Result from API

struct ScanResult: Codable {
    let timestamp: String
    let results: [TickerAnalysis]
    let rawTickerCount: Int

    var formattedTime: String {
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        var date = iso.date(from: timestamp)
        if date == nil {
            iso.formatOptions = [.withInternetDateTime]
            date = iso.date(from: timestamp)
        }
        guard let date else { return timestamp }
        let fmt = DateFormatter()
        fmt.dateStyle = .none
        fmt.timeStyle = .medium
        return fmt.string(from: date)
    }
}

// MARK: - Top Tickers Response

struct TopTickersResponse: Codable {
    let timestamp: String?
    let tickers: [TickerAnalysis]
}

// MARK: - Risk Level

enum RiskLevel: String, CaseIterable {
    case low = "Low"
    case medium = "Medium"
    case high = "High"
    case extreme = "Extreme"
}

// MARK: - Filter / Sort Options

enum TickerFilter: String, CaseIterable {
    case all = "All"
    case bullish = "Bullish"
    case bearish = "Bearish"
    case redFlags = "Red Flags"
    case highVolume = "High Volume"
}

enum TickerSort: String, CaseIterable {
    case investmentScore = "Invest Score"
    case sentimentScore = "Sentiment"
    case mentions = "Mentions"
    case priceChange = "Price Δ"
    case riskLevel = "Risk"
}

// MARK: - Notification Payload (from APNs custom data)

struct ScanNotificationData {
    let topTicker: String
    let topScore: Int
    let bearishCount: Int
    let bullishCount: Int
}
