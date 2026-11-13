// TickerViews.swift
// StockPulse — Ticker card and full detail sheet

import SwiftUI

// MARK: - Ticker Card

struct TickerCardView: View {
    let ticker: TickerAnalysis
    let rank: Int
    var isWatchlisted: Bool = false
    var onWatchlistToggle: (() -> Void)? = nil
    @State private var expanded = false

    private var investColor: Color {
        ticker.investmentScore > 65 ? .spAccentBlue :
        ticker.investmentScore < 40 ? .spAccentOrange : Color(hex: "AB47BC")
    }
    private var sentColor: Color {
        ticker.sentimentScore > 65 ? .spAccentGreen :
        ticker.sentimentScore < 40 ? .spAccentRed : .spAccentYellow
    }
    private var cardBg: LinearGradient {
        if ticker.negativeTraction {
            return LinearGradient(
                colors: [Color.spAccentRed.opacity(0.08), Color.spCard],
                startPoint: .topLeading, endPoint: .bottomTrailing
            )
        }
        if ticker.redFlag {
            return LinearGradient(
                colors: [Color.spAccentOrange.opacity(0.07), Color.spCard],
                startPoint: .topLeading, endPoint: .bottomTrailing
            )
        }
        return LinearGradient(
            colors: [Color.white.opacity(0.03), Color.spCard],
            startPoint: .topLeading, endPoint: .bottomTrailing
        )
    }
    private var borderColor: Color {
        ticker.negativeTraction ? .spAccentRed.opacity(0.25) :
        ticker.redFlag ? .spAccentOrange.opacity(0.2) : .spCardBorder
    }

    // Body is split into small subviews — Swift 5.7's type-checker times out
    // on one giant expression this deep/nested; extraction lets it check
    // each section independently.
    var body: some View {
        VStack(spacing: 0) {
            mainRow
                .padding(14)
                .contentShape(Rectangle())
                .onTapGesture { toggleExpanded() }

            if !expanded && (ticker.recommendation == "AVOID" || ticker.recommendation == "SHORT_WATCH") {
                avoidNudge
            }

            if expanded {
                expandedDetail
            }
        }
        .background(cardBg)
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(borderColor, lineWidth: 1))
        .cornerRadius(14)
        .animation(.easeInOut(duration: 0.25), value: expanded)
    }

    private func toggleExpanded() {
        expanded.toggle()
        if expanded {
            Analytics.capture("ticker_card_expanded", [
                "ticker": ticker.ticker,
                "rank": rank,
                "recommendation": ticker.recommendation,
                "investment_score": ticker.investmentScore,
            ])
        } else {
            Analytics.capture("ticker_card_collapsed", ["ticker": ticker.ticker])
        }
    }

    // MARK: - Main Row (tap here to expand/collapse)

    private var mainRow: some View {
        HStack(alignment: .center, spacing: 12) {
            // Rank
            Text("#\(rank)")
                .font(.system(size: 11, weight: .black, design: .monospaced))
                .foregroundColor(.spTextDim)
                .frame(width: 28)

            // Ticker + meta
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(ticker.ticker)
                        .font(.system(size: 20, weight: .black, design: .monospaced))
                        .foregroundColor(.spTextPrimary)

                    if ticker.negativeTraction {
                        BadgeView(text: "⚠ BEAR", color: .spAccentRed)
                    } else if ticker.redFlag {
                        BadgeView(text: "🚩 FLAG", color: .spAccentOrange)
                    }

                    BadgeView(
                        text: ticker.recommendation,
                        color: .recommendationColor(ticker.recommendation),
                        filled: ticker.recommendation == "BUY"
                    )
                }

                HStack(spacing: 6) {
                    // Price
                    if ticker.currentPrice > 0 {
                        Text("$\(String(format: "%.2f", ticker.currentPrice))")
                            .font(.system(size: 11, weight: .semibold, design: .monospaced))
                            .foregroundColor(.spTextSecondary)
                        Text(ticker.priceChangeFormatted)
                            .font(.system(size: 11, weight: .bold, design: .monospaced))
                            .foregroundColor(ticker.isPositive ? .spAccentGreen : .spAccentRed)
                        Text("·")
                            .foregroundColor(.spTextDim)
                    }
                    Text("\(ticker.totalMentions) mentions")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(.spTextDim)
                }
                .lineLimit(1)
                .minimumScaleFactor(0.85)

                Text(ticker.sentimentLabelShort + " · \(ticker.riskLevel) Risk")
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .foregroundColor(.riskColor(ticker.riskLevel))
            }

            Spacer()

            // Score Rings — fixed to 2 rings so layout is stable on all screen sizes
            HStack(spacing: 8) {
                ScoreRingView(score: ticker.investmentScore, label: "INVEST", color: investColor, size: 62)
                ScoreRingView(score: ticker.sentimentScore, label: "SNTMT", color: sentColor, size: 62)
            }
        }
    }

    // MARK: - Avoid nudge (collapsed only)

    private var avoidNudge: some View {
        let nudgeColor: Color = ticker.recommendation == "AVOID" ? .spAccentRed : .spAccentOrange
        return HStack(spacing: 5) {
            Image(systemName: "hand.tap")
                .font(.system(size: 10))
            Text("Tap to see why StockPulse flags this as \(ticker.recommendation.replacingOccurrences(of: "_", with: " "))")
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
        }
        .foregroundColor(nudgeColor)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 7)
        .background(nudgeColor.opacity(0.08))
    }

    // MARK: - Expanded Detail

    private var expandedDetail: some View {
        VStack(alignment: .leading, spacing: 12) {
            Divider().background(Color.spCardBorder)
            analystSummarySection
            statsRow
            actionButtonsRow
            Group {
                stockTwitsSection
                newsSection
                insiderTradesSection
                redditPostsSection
                catalystsSection
                subredditBreakdownSection
            }
            SentimentBarView(
                bullish: ticker.bullishCount,
                neutral: ticker.neutralCount,
                bearish: ticker.bearishCount
            )
            .padding(.horizontal, 14)

            // ── Data Sources Attribution ──────────────────────
            SourcesRowView(ticker: ticker)
                .padding(.horizontal, 14)
                .padding(.bottom, 14)
        }
        .transition(.opacity.combined(with: .move(edge: .top)))
    }

    // ── Avoid / Short_Watch reasoning callout, else plain analyst summary ────
    @ViewBuilder
    private var analystSummarySection: some View {
        if ticker.recommendation == "AVOID" || ticker.recommendation == "SHORT_WATCH" {
            let calloutColor: Color = ticker.recommendation == "AVOID" ? .spAccentRed : .spAccentOrange
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    Image(systemName: ticker.recommendation == "AVOID" ? "xmark.circle.fill" : "eye.trianglebadge.exclamationmark")
                        .font(.system(size: 12))
                    Text("WHY STOCKPULSE SAYS \(ticker.recommendation.replacingOccurrences(of: "_", with: " "))")
                        .font(.system(size: 10, weight: .black, design: .monospaced))
                        .tracking(1)
                }
                .foregroundColor(calloutColor)

                Text(ticker.analystSummary)
                    .font(.system(size: 13, design: .serif))
                    .foregroundColor(.spTextPrimary)
                    .lineSpacing(5)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(calloutColor.opacity(0.08))
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(calloutColor.opacity(0.3), lineWidth: 1)
            )
            .cornerRadius(10)
            .padding(.horizontal, 14)
        } else {
            // Analyst Summary (normal, non-avoid cards)
            Text(ticker.analystSummary)
                .font(.system(size: 13, design: .serif))
                .foregroundColor(.spTextSecondary)
                .lineSpacing(4)
                .padding(.horizontal, 14)
        }
    }

    private var statsRow: some View {
        HStack(spacing: 8) {
            StatBoxView(label: "5D CHANGE", value: ticker.weekChangeFormatted,
                        color: ticker.weekChangePct >= 0 ? .spAccentGreen : .spAccentRed)
            StatBoxView(label: "VOLUME", value: ticker.volumeFormatted, color: .spAccentBlue)
            StatBoxView(label: "MKT CAP", value: ticker.marketCap, color: .spAccentYellow)
        }
        .padding(.horizontal, 14)
    }

    // ── Action buttons: Watchlist + Yahoo Finance ────
    @ViewBuilder
    private var actionButtonsRow: some View {
        HStack(spacing: 8) {
            // Watchlist toggle
            if let toggle = onWatchlistToggle {
                Button(action: toggle) {
                    HStack(spacing: 6) {
                        Image(systemName: isWatchlisted ? "bookmark.fill" : "bookmark")
                            .font(.system(size: 12))
                        Text(isWatchlisted ? "Watching" : "Watchlist")
                            .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    }
                    .foregroundColor(isWatchlisted ? .spAccentYellow : .spTextSecondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 9)
                    .background(isWatchlisted ? Color.spAccentYellow.opacity(0.12) : Color.white.opacity(0.06))
                    .cornerRadius(8)
                }
                .buttonStyle(.plain)
            }

            // Yahoo Finance link
            if let yfURL = URL(string: "https://finance.yahoo.com/quote/\(ticker.ticker)") {
                Link(destination: yfURL) {
                    HStack(spacing: 6) {
                        Image(systemName: "chart.xyaxis.line")
                            .font(.system(size: 12))
                        Text("Yahoo Finance")
                            .font(.system(size: 11, weight: .semibold, design: .monospaced))
                        Image(systemName: "arrow.up.right.square")
                            .font(.system(size: 11))
                    }
                    .foregroundColor(.spAccentBlue)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 9)
                    .background(Color.spAccentBlue.opacity(0.07))
                    .cornerRadius(8)
                }
                .simultaneousGesture(TapGesture().onEnded {
                    Analytics.capture("yahoo_finance_tapped", ["ticker": ticker.ticker])
                })
            }
        }
        .padding(.horizontal, 14)
    }

    // ── StockTwits messages ──────────────────────────
    @ViewBuilder
    private var stockTwitsSection: some View {
        if !ticker.safeStockTwitsMessages.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text("STOCKTWITS")
                    .font(.system(size: 9, weight: .black, design: .monospaced))
                    .foregroundColor(.spTextDim)
                    .tracking(1.5)

                ForEach(ticker.safeStockTwitsMessages.prefix(3)) { msg in
                    stockTwitsRow(msg)
                }
            }
            .padding(.horizontal, 14)
        }
    }

    @ViewBuilder
    private func stockTwitsRow(_ msg: StockTwitsMessage) -> some View {
        let content = VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text("@\(msg.username)")
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .foregroundColor(Color(hex: "26C6DA"))
                if let sentiment = msg.sentiment {
                    BadgeView(
                        text: sentiment.uppercased(),
                        color: sentiment == "Bullish" ? .spAccentGreen : .spAccentRed
                    )
                }
                Spacer()
                HStack(spacing: 3) {
                    if msg.likes > 0 {
                        Image(systemName: "heart.fill")
                            .font(.system(size: 9))
                        Text("\(msg.likes)")
                            .font(.system(size: 9, design: .monospaced))
                    }
                    Text(msg.timeAgo)
                        .font(.system(size: 9, design: .monospaced))
                    Image(systemName: "arrow.up.right")
                        .font(.system(size: 9))
                }
                .foregroundColor(.spTextDim)
            }
            Text(msg.body)
                .font(.system(size: 11, design: .serif))
                .foregroundColor(.spTextSecondary)
                .lineLimit(3)
                .multilineTextAlignment(.leading)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(Color(hex: "26C6DA").opacity(0.05))
        .cornerRadius(7)

        if let url = msg.messageURL {
            Link(destination: url) { content }
                .simultaneousGesture(TapGesture().onEnded {
                    Analytics.capture("stocktwits_message_tapped", ["ticker": ticker.ticker])
                })
        } else {
            content
        }
    }

    // ── News RSS ─────────────────────────────────────
    @ViewBuilder
    private var newsSection: some View {
        if !ticker.safeNewsItems.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text("NEWS")
                    .font(.system(size: 9, weight: .black, design: .monospaced))
                    .foregroundColor(.spTextDim)
                    .tracking(1.5)

                ForEach(ticker.safeNewsItems.prefix(3)) { item in
                    newsRow(item)
                }
            }
            .padding(.horizontal, 14)
        }
    }

    @ViewBuilder
    private func newsRow(_ item: NewsItem) -> some View {
        let rowContent = HStack(alignment: .top, spacing: 8) {
            Image(systemName: "newspaper")
                .font(.system(size: 10))
                .foregroundColor(Color(hex: "A78BFA"))
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.headline)
                    .font(.system(size: 11, design: .serif))
                    .foregroundColor(.spTextSecondary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                HStack(spacing: 6) {
                    Text(item.source)
                        .font(.system(size: 9, weight: .semibold, design: .monospaced))
                        .foregroundColor(Color(hex: "A78BFA"))
                    if !item.timeAgo.isEmpty {
                        Text("· \(item.timeAgo)")
                            .font(.system(size: 9, design: .monospaced))
                            .foregroundColor(.spTextDim)
                    }
                }
            }
            Spacer()
            Image(systemName: "arrow.up.right")
                .font(.system(size: 9))
                .foregroundColor(.spTextDim)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(Color(hex: "A78BFA").opacity(0.05))
        .cornerRadius(7)

        if let url = URL(string: item.url), !item.url.isEmpty {
            Link(destination: url) { rowContent }
                .simultaneousGesture(TapGesture().onEnded {
                    Analytics.capture("news_link_tapped", [
                        "ticker": ticker.ticker,
                        "source": item.source,
                    ])
                })
        } else {
            rowContent
        }
    }

    // ── SEC Form 4 Insider Trades ─────────────────────
    @ViewBuilder
    private var insiderTradesSection: some View {
        if let count = ticker.insiderTradeCount, count > 0 {
            let edgarURL = ticker.insiderTradeUrl.flatMap { URL(string: $0) }
            let badge = HStack(spacing: 8) {
                Image(systemName: "building.columns")
                    .font(.system(size: 11))
                    .foregroundColor(Color(hex: "34D399"))
                VStack(alignment: .leading, spacing: 2) {
                    Text("SEC FORM 4 — INSIDER ACTIVITY")
                        .font(.system(size: 9, weight: .black, design: .monospaced))
                        .foregroundColor(Color(hex: "34D399"))
                        .tracking(1)
                    Text("\(count) insider filing\(count == 1 ? "" : "s") in the last 30 days")
                        .font(.system(size: 11, design: .serif))
                        .foregroundColor(.spTextSecondary)
                }
                Spacer()
                Image(systemName: "arrow.up.right")
                    .font(.system(size: 9))
                    .foregroundColor(.spTextDim)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background(Color(hex: "34D399").opacity(0.06))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(Color(hex: "34D399").opacity(0.25), lineWidth: 1)
            )
            .cornerRadius(8)
            .padding(.horizontal, 14)

            if let url = edgarURL {
                Link(destination: url) { badge }
                    .simultaneousGesture(TapGesture().onEnded {
                        Analytics.capture("sec_edgar_tapped", [
                            "ticker": ticker.ticker,
                            "filing_count": count,
                        ])
                    })
            } else {
                badge
            }
        }
    }

    // ── Reddit posts ─────────────────────────────────
    @ViewBuilder
    private var redditPostsSection: some View {
        if !ticker.safeRedditPosts.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text("REDDIT POSTS")
                    .font(.system(size: 9, weight: .black, design: .monospaced))
                    .foregroundColor(.spTextDim)
                    .tracking(1.5)

                ForEach(ticker.safeRedditPosts.prefix(3)) { post in
                    redditPostRow(post)
                }
            }
            .padding(.horizontal, 14)
        }
    }

    @ViewBuilder
    private func redditPostRow(_ post: RedditPost) -> some View {
        if let url = URL(string: post.url) {
            Link(destination: url) {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "arrow.up.circle")
                        .font(.system(size: 10))
                        .foregroundColor(.spAccentOrange)
                        .padding(.top, 1)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(post.title)
                            .font(.system(size: 11, design: .serif))
                            .foregroundColor(.spTextSecondary)
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                        Text("\(post.score) upvotes")
                            .font(.system(size: 9, design: .monospaced))
                            .foregroundColor(.spTextDim)
                    }
                    Spacer()
                    Image(systemName: "arrow.up.right")
                        .font(.system(size: 9))
                        .foregroundColor(.spTextDim)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(Color.white.opacity(0.04))
                .cornerRadius(7)
            }
            .simultaneousGesture(TapGesture().onEnded {
                Analytics.capture("reddit_post_tapped", [
                    "ticker": ticker.ticker,
                    "upvotes": post.score,
                ])
            })
        }
    }

    // Catalysts
    @ViewBuilder
    private var catalystsSection: some View {
        if !ticker.catalysts.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text("CATALYSTS")
                    .font(.system(size: 9, weight: .black, design: .monospaced))
                    .foregroundColor(.spTextDim)
                    .tracking(1.5)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(ticker.catalysts, id: \.self) { cat in
                            Text(cat)
                                .font(.system(size: 11, design: .serif))
                                .foregroundColor(.spTextSecondary)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 5)
                                .background(Color.white.opacity(0.05))
                                .cornerRadius(6)
                        }
                    }
                }
            }
            .padding(.horizontal, 14)
        }
    }

    // Subreddit Breakdown
    private var subredditBreakdownSection: some View {
        let sortedSubs = ticker.subredditBreakdown
            .sorted { $0.value > $1.value }
        return ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(sortedSubs, id: \.key) { sub, count in
                    SubredditPill(sub: sub, count: count)
                }
            }
            .padding(.horizontal, 14)
        }
    }
}

// MARK: - Sentiment Bar

struct SentimentBarView: View {
    let bullish: Int
    let neutral: Int
    let bearish: Int

    private var total: Int { bullish + neutral + bearish }
    private var bullRatio: CGFloat { total > 0 ? CGFloat(bullish) / CGFloat(total) : 0 }
    private var neutRatio: CGFloat { total > 0 ? CGFloat(neutral) / CGFloat(total) : 0 }
    private var bearRatio: CGFloat { total > 0 ? CGFloat(bearish) / CGFloat(total) : 0 }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("REDDIT SENTIMENT BREAKDOWN")
                .font(.system(size: 9, weight: .black, design: .monospaced))
                .foregroundColor(.spTextDim)
                .tracking(1.5)

            GeometryReader { geo in
                HStack(spacing: 2) {
                    RoundedRectangle(cornerRadius: 3)
                        .fill(Color.spAccentGreen)
                        .frame(width: geo.size.width * bullRatio)
                    RoundedRectangle(cornerRadius: 3)
                        .fill(Color.spAccentYellow)
                        .frame(width: geo.size.width * neutRatio)
                    RoundedRectangle(cornerRadius: 3)
                        .fill(Color.spAccentRed)
                        .frame(width: geo.size.width * bearRatio)
                }
            }
            .frame(height: 6)
            .cornerRadius(3)

            HStack {
                Label("\(bullish) bull", systemImage: "arrow.up")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(.spAccentGreen)
                Spacer()
                Text("\(neutral) neutral")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(.spAccentYellow)
                Spacer()
                Label("\(bearish) bear", systemImage: "arrow.down")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(.spAccentRed)
            }
        }
    }
}

// MARK: - Data Sources Attribution Row

struct SourcesRowView: View {
    let ticker: TickerAnalysis

    private struct SourceChip: View {
        let label: String
        let icon: String
        let color: Color
        let active: Bool

        var body: some View {
            HStack(spacing: 3) {
                Image(systemName: icon)
                    .font(.system(size: 8))
                Text(label)
                    .font(.system(size: 8, weight: .bold, design: .monospaced))
            }
            .foregroundColor(active ? color : Color.spTextDim.opacity(0.4))
            .padding(.horizontal, 7)
            .padding(.vertical, 4)
            .background((active ? color : Color.gray).opacity(active ? 0.12 : 0.05))
            .cornerRadius(5)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("DATA SOURCES")
                .font(.system(size: 8, weight: .black, design: .monospaced))
                .foregroundColor(.spTextDim)
                .tracking(1.5)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 5) {
                    SourceChip(
                        label: "Reddit",
                        icon: "bubble.left.and.bubble.right",
                        color: Color(hex: "FF4500"),
                        active: ticker.totalMentions > 0
                    )
                    SourceChip(
                        label: "StockTwits",
                        icon: "chart.line.uptrend.xyaxis",
                        color: Color(hex: "26C6DA"),
                        active: (ticker.stocktwitsRank ?? 0) > 0 || !ticker.safeStockTwitsMessages.isEmpty
                    )
                    SourceChip(
                        label: "Google Trends",
                        icon: "magnifyingglass",
                        color: Color(hex: "4285F4"),
                        active: (ticker.googleTrendsScore ?? 0) > 0
                    )
                    SourceChip(
                        label: "News RSS",
                        icon: "newspaper",
                        color: Color(hex: "A78BFA"),
                        active: !ticker.safeNewsItems.isEmpty
                    )
                    SourceChip(
                        label: "SEC Form 4",
                        icon: "building.columns",
                        color: Color(hex: "34D399"),
                        active: (ticker.insiderTradeCount ?? 0) > 0
                    )
                }
            }
        }
    }
}

// MARK: - Top Post Snippet

struct TopPostView: View {
    let post: String
    let sub: String

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Circle()
                .fill(Color.subColor(sub))
                .frame(width: 6, height: 6)
                .padding(.top, 5)
            Text(post)
                .font(.system(size: 12, design: .serif))
                .foregroundColor(.spTextSecondary)
                .lineLimit(2)
        }
    }
}
