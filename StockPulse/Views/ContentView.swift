// ContentView.swift
// StockPulse — Root navigation and main radar screen

import SwiftUI

struct ContentView: View {
    @StateObject private var vm = StockViewModel()
    @State private var selectedTab = 0
    @AppStorage("isDarkMode") private var isDarkMode = true
    @AppStorage("hasSeenOnboarding") private var hasSeenOnboarding = false
    @AppStorage("hasAcceptedDisclaimer") private var hasAcceptedDisclaimer = false

    var body: some View {
        ZStack(alignment: .bottom) {
            Color.spBackground.ignoresSafeArea()

            TabView(selection: $selectedTab) {
                RadarView(vm: vm)
                    .tag(0)
                WatchlistView(vm: vm)
                    .tag(1)
                AlertsView(vm: vm)
                    .tag(2)
                SettingsView(vm: vm, isDarkMode: $isDarkMode)
                    .tag(3)
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            .onChange(of: selectedTab) { tab in
                let names = ["radar", "watchlist", "alerts", "settings"]
                Analytics.capture("tab_switched", ["tab": names[safe: tab] ?? "\(tab)"])
            }

            // Custom Tab Bar
            CustomTabBar(selectedTab: $selectedTab)
        }
        .preferredColorScheme(isDarkMode ? .dark : .light)
        // Switch to Watchlist tab when a watchlist notification is tapped
        .onReceive(NotificationCenter.default.publisher(for: .switchToWatchlistTab)) { _ in
            selectedTab = 1
        }
        // Disclaimer fires first — no entry without acceptance
        .fullScreenCover(isPresented: .constant(!hasAcceptedDisclaimer)) {
            DisclaimerView { hasAcceptedDisclaimer = true }
                .preferredColorScheme(.dark)
        }
        // Onboarding fires only after disclaimer is accepted
        .fullScreenCover(isPresented: .constant(hasAcceptedDisclaimer && !hasSeenOnboarding)) {
            OnboardingView { hasSeenOnboarding = true }
                .preferredColorScheme(.dark)
        }
    }
}

// MARK: - Custom Tab Bar

struct CustomTabBar: View {
    @Binding var selectedTab: Int

    private let tabs: [(icon: String, label: String)] = [
        ("dot.radiowaves.left.and.right", "Radar"),
        ("bookmark.fill",                 "Watchlist"),
        ("bell.badge",                    "Alerts"),
        ("gearshape",                     "Settings"),
    ]

    var body: some View {
        HStack {
            ForEach(tabs.indices, id: \.self) { i in
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) { selectedTab = i }
                } label: {
                    VStack(spacing: 4) {
                        Image(systemName: tabs[i].icon)
                            .font(.system(size: 20, weight: selectedTab == i ? .bold : .regular))
                            .foregroundColor(selectedTab == i ? .spReddit : .spTextDim)
                        Text(tabs[i].label)
                            .font(.system(size: 9, weight: .bold, design: .monospaced))
                            .foregroundColor(selectedTab == i ? .spReddit : .spTextDim)
                    }
                    .frame(maxWidth: .infinity)
                }
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 12)
        .padding(.bottom, 28)
        .background(
            Color.spBackground.opacity(0.97)
                .overlay(
                    Rectangle()
                        .fill(Color.spCardBorder)
                        .frame(height: 1),
                    alignment: .top
                )
        )
    }
}

// MARK: - Radar View (Main Screen)

struct RadarView: View {
    @ObservedObject var vm: StockViewModel
    @State private var showSortSheet = false

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(spacing: 0) {
                // Header
                HeaderView(vm: vm)

                // Sub Filter
                SubredditFilterBar(
                    selected: $vm.selectedSubreddit,
                    available: vm.availableSubreddits
                )
                .padding(.bottom, 8)

                // Category Tabs
                CategoryTabBar(selected: $vm.selectedFilter)
                    .padding(.bottom, 4)

                // Sort Controls
                HStack {
                    Text("\(vm.filteredTickers.count) tickers")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(.spTextDim)
                    Spacer()
                    Button { showSortSheet = true } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "arrow.up.arrow.down")
                            Text(vm.selectedSort.rawValue)
                        }
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                        .foregroundColor(.spTextSecondary)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 8)

                // Ticker List
                if vm.isLoading && vm.allTickers.isEmpty {
                    VStack(spacing: 16) {
                        SpinnerView()
                        Text("Fetching latest market pulse...")
                            .font(.system(size: 13, design: .serif))
                            .foregroundColor(.spTextSecondary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(60)
                } else if vm.filteredTickers.isEmpty {
                    let emptyMsg: String = {
                        switch vm.selectedFilter {
                        case .bearish:    return "No bearish tickers in this update — sentiment is currently bullish across the board"
                        case .redFlags:   return "No red flags detected — no manipulation signals found in this update"
                        case .bullish:    return "No strongly bullish tickers detected yet — try refreshing"
                        case .highVolume: return "No high-volume tickers detected in this update"
                        default:          return "No tickers match the current filter"
                        }
                    }()
                    EmptyStateView(icon: vm.selectedFilter == .bearish ? "🐻" : "📡", message: emptyMsg)
                } else {
                    LazyVStack(spacing: 10) {
                        ForEach(Array(vm.filteredTickers.enumerated()), id: \.element.id) { idx, ticker in
                            TickerCardView(
                                ticker: ticker,
                                rank: idx + 1,
                                isWatchlisted: vm.isInWatchlist(ticker.ticker),
                                onWatchlistToggle: {
                                    vm.isInWatchlist(ticker.ticker)
                                        ? vm.removeFromWatchlist(ticker.ticker)
                                        : vm.addToWatchlist(ticker.ticker)
                                }
                            )
                            .padding(.horizontal, 16)
                        }
                    }
                    .padding(.bottom, 100)
                }
            }
        }
        .refreshable {
            Analytics.capture("pull_to_refresh")
            await vm.fetchData()
        }
        .sheet(isPresented: $showSortSheet) { SortSheet(selected: $vm.selectedSort) }
        .alert("Error", isPresented: $vm.showError, actions: {
            Button("OK") { vm.showError = false }
        }, message: { Text(vm.errorMessage ?? "Unknown error") })
    }
}

// MARK: - Header

struct HeaderView: View {
    @ObservedObject var vm: StockViewModel

    var body: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 2) {
                Text("REDDIT RADAR")
                    .font(.system(size: 10, weight: .black, design: .monospaced))
                    .foregroundColor(.spTextDim)
                    .tracking(3)

                HStack(alignment: .firstTextBaseline, spacing: 2) {
                    Text("Stock")
                        .font(.system(size: 28, weight: .black, design: .monospaced))
                        .foregroundColor(.spTextPrimary)
                    Text("Pulse")
                        .font(.system(size: 28, weight: .black, design: .monospaced))
                        .foregroundColor(.spReddit)
                }

                if let updated = vm.lastUpdated {
                    Text("Updated \(updated.formatted(date: .omitted, time: .shortened))")
                        .font(.system(size: 10, design: .serif))
                        .foregroundColor(.spTextDim)
                }
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 4) {
                // Server status dot
                Circle()
                    .fill(vm.isServerOnline ? Color.spAccentGreen : Color.spAccentRed)
                    .frame(width: 7, height: 7)

                Text("NEXT UPDATE")
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundColor(.spTextDim)

                Text(vm.isLoading ? "LOADING" : vm.countdownFormatted)
                    .font(.system(size: 24, weight: .black, design: .monospaced))
                    .foregroundColor(vm.isLoading ? .spReddit : .spAccentGreen)
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 56)
        .padding(.bottom, 16)
    }
}

// MARK: - Subreddit Filter Bar

struct SubredditFilterBar: View {
    @Binding var selected: String
    let available: [String]

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(available, id: \.self) { sub in
                    let isSelected = selected == sub
                    let sub_clean = sub.replacingOccurrences(of: "r/", with: "")
                    let color = sub == "All" ? Color.spReddit : Color.subColor(sub_clean)

                    Button {
                        Analytics.capture("subreddit_filter_changed", ["subreddit": sub])
                        selected = sub
                    } label: {
                        Text(sub == "All" ? "All Subs" : sub)
                            .font(.system(size: 11, weight: isSelected ? .black : .regular, design: .monospaced))
                            .foregroundColor(isSelected ? (sub == "All" ? .black : .black) : .spTextDim)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(isSelected ? color : Color.white.opacity(0.04))
                            .cornerRadius(20)
                    }
                }
            }
            .padding(.horizontal, 16)
        }
    }
}

// MARK: - Category Tab Bar

struct CategoryTabBar: View {
    @Binding var selected: TickerFilter

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 0) {
                ForEach(TickerFilter.allCases, id: \.self) { filter in
                    let isSelected = selected == filter
                    let color: Color = filter == .bearish ? .spAccentRed :
                                      filter == .redFlags ? .spAccentOrange : .spAccentGreen

                    Button {
                        Analytics.capture("category_filter_changed", ["filter": filter.rawValue])
                        selected = filter
                    } label: {
                        Text(filter.rawValue)
                            .font(.system(size: 12, weight: isSelected ? .black : .medium, design: .monospaced))
                            .foregroundColor(isSelected ? color : .spTextDim)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 10)
                            .overlay(
                                Rectangle()
                                    .fill(isSelected ? color : Color.clear)
                                    .frame(height: 2),
                                alignment: .bottom
                            )
                    }
                }
            }
            .padding(.horizontal, 8)
        }
        .background(
            Rectangle()
                .fill(Color.spCardBorder)
                .frame(height: 1),
            alignment: .bottom
        )
    }
}

// MARK: - Sort Bottom Sheet

struct SortSheet: View {
    @Binding var selected: TickerSort
    @Environment(\.dismiss) var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("SORT BY")
                .font(.system(size: 12, weight: .black, design: .monospaced))
                .foregroundColor(.spTextDim)
                .tracking(2)
                .padding(20)

            ForEach(TickerSort.allCases, id: \.self) { sort in
                Button {
                    Analytics.capture("sort_changed", ["sort": sort.rawValue])
                    selected = sort
                    dismiss()
                } label: {
                    HStack {
                        Text(sort.rawValue)
                            .font(.system(size: 15, weight: .semibold, design: .monospaced))
                            .foregroundColor(selected == sort ? .spReddit : .spTextPrimary)
                        Spacer()
                        if selected == sort {
                            Image(systemName: "checkmark")
                                .foregroundColor(.spReddit)
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.vertical, 14)
                }
                Divider().background(Color.spCardBorder).padding(.horizontal, 20)
            }
        }
        .background(Color.spCard)
        .presentationDetents([.height(320)])
        .presentationDragIndicator(.visible)
    }
}

// MARK: - Alerts View

struct AlertsView: View {
    @ObservedObject var vm: StockViewModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("RED FLAGS & ALERTS")
                    .font(.system(size: 12, weight: .black, design: .monospaced))
                    .foregroundColor(.spTextDim)
                    .tracking(2)
                    .padding(.top, 60)
                    .padding(.horizontal, 16)

                if vm.redFlagTickers.isEmpty && vm.negativeTickers.isEmpty {
                    EmptyStateView(icon: "✅", message: "No red flags detected in latest update")
                } else {
                    if !vm.negativeTickers.isEmpty {
                        SectionHeaderView(title: "BEARISH TRACTION", count: vm.negativeTickers.count, color: .spAccentRed)
                        ForEach(Array(vm.negativeTickers.enumerated()), id: \.element.id) { idx, t in
                            TickerCardView(
                                ticker: t, rank: idx + 1,
                                isWatchlisted: vm.isInWatchlist(t.ticker),
                                onWatchlistToggle: {
                                    vm.isInWatchlist(t.ticker)
                                        ? vm.removeFromWatchlist(t.ticker)
                                        : vm.addToWatchlist(t.ticker)
                                }
                            ).padding(.horizontal, 16)
                        }
                    }
                    if !vm.redFlagTickers.isEmpty {
                        SectionHeaderView(title: "RED FLAG ALERTS", count: vm.redFlagTickers.count, color: .spAccentOrange)
                        ForEach(Array(vm.redFlagTickers.enumerated()), id: \.element.id) { idx, t in
                            TickerCardView(
                                ticker: t, rank: idx + 1,
                                isWatchlisted: vm.isInWatchlist(t.ticker),
                                onWatchlistToggle: {
                                    vm.isInWatchlist(t.ticker)
                                        ? vm.removeFromWatchlist(t.ticker)
                                        : vm.addToWatchlist(t.ticker)
                                }
                            ).padding(.horizontal, 16)
                        }
                    }
                }
            }
            .padding(.bottom, 100)
        }
        .background(Color.spBackground)
    }
}

// MARK: - Settings View

struct SettingsView: View {
    @ObservedObject var vm: StockViewModel
    @Binding var isDarkMode: Bool

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                Text("SETTINGS")
                    .font(.system(size: 12, weight: .black, design: .monospaced))
                    .foregroundColor(.spTextDim)
                    .tracking(2)
                    .padding(.top, 60)
                    .padding(.horizontal, 16)

                // Appearance
                VStack(alignment: .leading, spacing: 12) {
                    Text("APPEARANCE")
                        .font(.system(size: 10, weight: .black, design: .monospaced))
                        .foregroundColor(.spTextDim)
                        .tracking(1.5)
                        .padding(.horizontal, 16)

                    HStack {
                        Text("Theme")
                            .font(.system(size: 13, design: .monospaced))
                            .foregroundColor(.spTextSecondary)
                        Spacer()
                        HStack(spacing: 0) {
                            ForEach([(false, "☀️  Light"), (true, "🌙  Dark")], id: \.1) { dark, label in
                                Button {
                                    withAnimation(.easeInOut(duration: 0.25)) { isDarkMode = dark }
                                    let theme: String = dark ? "dark" : "light"
                                    Analytics.capture("theme_changed", ["theme": theme])
                                } label: {
                                    Text(label)
                                        .font(.system(size: 12, weight: .bold, design: .monospaced))
                                        .padding(.horizontal, 14)
                                        .padding(.vertical, 7)
                                        .background(isDarkMode == dark ? Color.spReddit : Color.clear)
                                        .foregroundColor(isDarkMode == dark ? .white : .spTextDim)
                                }
                            }
                        }
                        .background(Color.white.opacity(0.07))
                        .cornerRadius(8)
                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.spCardBorder, lineWidth: 1))
                    }
                    .padding(.horizontal, 16)
                }

                // Pro upgrade
                ProSectionView()

                // Contact Us
                ContactSectionView()

                // Support
                SupportSectionView()

                // FAQ
                FAQSectionView()

                // About
                AboutSectionView()
            }
            .padding(.bottom, 100)
        }
        .background(Color.spBackground)
    }
}

// MARK: - Pro Section

struct ProSectionView: View {
    @StateObject private var purchases = PurchaseService.shared
    @State private var showPaywall = false
    @State private var isRestoring = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("STOCKPULSE PRO")
                .font(.system(size: 10, weight: .black, design: .monospaced))
                .foregroundColor(.spTextDim)
                .tracking(1.5)
                .padding(.horizontal, 16)

            VStack(spacing: 1) {
                if purchases.isPremium {
                    HStack {
                        Image(systemName: "checkmark.seal.fill")
                            .foregroundColor(.spAccentGreen)
                        Text("Pro unlocked — unlimited watchlist")
                            .font(.system(size: 13, design: .monospaced))
                            .foregroundColor(.spTextSecondary)
                        Spacer()
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 14)
                    .background(Color.white.opacity(0.04))
                    .cornerRadius(12)
                    .padding(.horizontal, 16)
                } else {
                    Button {
                        showPaywall = true
                    } label: {
                        HStack {
                            Image(systemName: "lock.open.fill")
                                .foregroundColor(.spReddit)
                            Text("Unlock unlimited watchlist — \(purchases.formattedPrice)")
                                .font(.system(size: 13, design: .monospaced))
                                .foregroundColor(.spTextSecondary)
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.system(size: 12))
                                .foregroundColor(.spTextDim)
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 14)
                        .background(Color.white.opacity(0.04))
                        .cornerRadius(12)
                        .padding(.horizontal, 16)
                    }

                    Button {
                        isRestoring = true
                        Task {
                            await purchases.restore()
                            isRestoring = false
                        }
                    } label: {
                        HStack {
                            Image(systemName: "arrow.clockwise")
                                .foregroundColor(.spTextDim)
                            Text(isRestoring ? "Restoring…" : "Restore purchase")
                                .font(.system(size: 13, design: .monospaced))
                                .foregroundColor(.spTextSecondary)
                            Spacer()
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 14)
                        .background(Color.white.opacity(0.04))
                        .cornerRadius(12)
                        .padding(.horizontal, 16)
                    }
                    .disabled(isRestoring)
                }
            }
        }
        .sheet(isPresented: $showPaywall) { PaywallView() }
    }
}

// MARK: - Contact Section

struct ContactSectionView: View {

    private let email = "stockpulse.app.help@gmail.com"

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("CONTACT US")
                .font(.system(size: 10, weight: .black, design: .monospaced))
                .foregroundColor(.spTextDim)
                .tracking(1.5)
                .padding(.horizontal, 16)

            VStack(spacing: 1) {
                    Button {
                        Analytics.capture("contact_us_tapped")
                        let urlString = "mailto:\(email)?subject=StockPulse%20Feedback"
                        if let url = URL(string: urlString) {
                            UIApplication.shared.open(url)
                        }
                    } label: {
                        HStack(spacing: 14) {
                            Image(systemName: "envelope")
                                .font(.system(size: 15))
                                .foregroundColor(.spAccentBlue)
                                .frame(width: 24)
                            Text("Contact Us")
                                .font(.system(size: 13, design: .monospaced))
                                .foregroundColor(.spTextPrimary)
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundColor(.spTextDim)
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 14)
                        .background(Color.spCard)
                    }
                    .buttonStyle(.plain)
            }
            .cornerRadius(12)
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.spCardBorder, lineWidth: 1))
            .padding(.horizontal, 16)

            Text("Reach us at \(email)")
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(.spTextDim)
                .padding(.horizontal, 16)
        }
    }
}

// MARK: - Support Section

struct SupportSectionView: View {
    @State private var showShareSheet = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("SUPPORT")
                .font(.system(size: 10, weight: .black, design: .monospaced))
                .foregroundColor(.spTextDim)
                .tracking(1.5)
                .padding(.horizontal, 16)

            VStack(spacing: 1) {
                // Tell a Friend
                Button {
                    Analytics.capture("share_sheet_opened")
                    showShareSheet = true
                } label: {
                    SettingsRow(icon: "person.2", iconColor: .spAccentGreen, label: "Tell a Friend")
                }
                .buttonStyle(.plain)
                .sheet(isPresented: $showShareSheet) {
                    ShareSheet(items: [
                        "Check out StockPulse — it tracks Reddit sentiment on stocks in real time!",
                        URL(string: "https://apps.apple.com/app/id6770486179")!
                    ])
                }

                Divider().background(Color.spCardBorder).padding(.leading, 54)

                // Donate
                Button {
                    Analytics.capture("donate_tapped")
                    if let url = URL(string: "https://www.paypal.com/donate?hosted_button_id=5A6THKCM3YSTU") {
                        UIApplication.shared.open(url)
                    }
                } label: {
                    SettingsRow(icon: "heart", iconColor: .spAccentRed, label: "Donate")
                }
                .buttonStyle(.plain)
            }
            .cornerRadius(12)
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.spCardBorder, lineWidth: 1))
            .padding(.horizontal, 16)
        }
    }
}

// MARK: - About Section

struct AboutSectionView: View {
    private var appVersion: String {
        let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        let b = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
        return "\(v) (\(b))"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("ABOUT")
                .font(.system(size: 10, weight: .black, design: .monospaced))
                .foregroundColor(.spTextDim)
                .tracking(1.5)
                .padding(.horizontal, 16)

            VStack(spacing: 1) {
                // Privacy Policy
                Button {
                    if let url = URL(string: "https://ameymankar.github.io/stock_pulse_app_terms/privacy.html") {
                        UIApplication.shared.open(url)
                    }
                } label: {
                    SettingsRow(icon: "lock.shield", iconColor: .spAccentBlue, label: "Privacy Policy")
                }
                .buttonStyle(.plain)

                Divider().background(Color.spCardBorder).padding(.leading, 54)

                // Terms of Use
                Button {
                    if let url = URL(string: "https://ameymankar.github.io/stock_pulse_app_terms/terms.html") {
                        UIApplication.shared.open(url)
                    }
                } label: {
                    SettingsRow(icon: "doc.text", iconColor: .spAccentBlue, label: "Terms of Use")
                }
                .buttonStyle(.plain)

                Divider().background(Color.spCardBorder).padding(.leading, 54)

                // App Version (non-tappable)
                HStack(spacing: 14) {
                    Image(systemName: "info.circle")
                        .font(.system(size: 15))
                        .foregroundColor(.spTextDim)
                        .frame(width: 24)
                    Text("App Version")
                        .font(.system(size: 13, design: .monospaced))
                        .foregroundColor(.spTextPrimary)
                    Spacer()
                    Text(appVersion)
                        .font(.system(size: 13, design: .monospaced))
                        .foregroundColor(.spTextDim)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 14)
                .background(Color.spCard)
            }
            .cornerRadius(12)
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.spCardBorder, lineWidth: 1))
            .padding(.horizontal, 16)
        }
    }
}

// MARK: - Reusable Settings Row

private struct SettingsRow: View {
    let icon: String
    let iconColor: Color
    let label: String

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: icon)
                .font(.system(size: 15))
                .foregroundColor(iconColor)
                .frame(width: 24)
            Text(label)
                .font(.system(size: 13, design: .monospaced))
                .foregroundColor(.spTextPrimary)
            Spacer()
            Image(systemName: "chevron.right")
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(.spTextDim)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .background(Color.spCard)
    }
}

// MARK: - Share Sheet

struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }
    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

// MARK: - FAQ Section

private struct FAQEntry {
    let question: String
    let answer: String
}

struct FAQSectionView: View {

    private let items: [FAQEntry] = [
        FAQEntry(
            question: "How is the Investment Score calculated?",
            answer: "The Investment Score (1–100) is generated by AI after analysing Reddit mention velocity, sentiment direction, price momentum, volume spike vs. average, and market cap context. A score above 70 suggests a strong opportunity; below 30 usually means avoid. It is not financial advice."
        ),
        FAQEntry(
            question: "How is the Sentiment Score calculated?",
            answer: "Every Reddit post and comment mentioning a ticker is run through VADER sentiment analysis, producing a value from –1 (very negative) to +1 (very positive). These are averaged across all mentions and scaled to 1–100. 50 is neutral, above 70 is strongly bullish, below 30 is strongly bearish."
        ),
        FAQEntry(
            question: "What do the recommendations mean?",
            answer: "BUY — strong bullish momentum with manageable risk.\nWATCH — interesting signal but not enough conviction yet.\nAVOID — bearish sentiment or insufficient data.\nSHORT_WATCH — ticker is trending downward or being discussed as a short opportunity."
        ),
        FAQEntry(
            question: "What is a Red Flag?",
            answer: "A red flag is raised when the AI detects patterns consistent with manipulation — sudden mention spikes on very low-cap stocks, coordinated hype language, or pump-and-dump signals. These tickers are displayed with a warning and should be treated with extra caution."
        ),
        FAQEntry(
            question: "What is Negative Traction?",
            answer: "Negative traction means the dominant Reddit discussion is bearish — people are warning against the stock, discussing it as a short, or sharing bad news. These appear in the Bearish tab so you can monitor both sides of the market."
        ),
        FAQEntry(
            question: "Where does the data come from?",
            answer: "StockPulse aggregates Reddit, StockTwits, Google Trends, financial news RSS, and SEC Form 4 insider filings — updated every 15 minutes. Price data is sourced from Yahoo Finance. AI analysis is powered by Claude (Anthropic)."
        ),
        FAQEntry(
            question: "Why might a ticker disappear between scans?",
            answer: "A ticker only appears if it received at least 2 Reddit mentions in the latest scrape AND passed validation against Yahoo Finance (confirming it is a real, tradeable symbol). Common words, abbreviations, and Reddit slang are filtered out automatically."
        ),
        FAQEntry(
            question: "Is this financial advice?",
            answer: "No. StockPulse is a Reddit sentiment analysis tool intended for research and entertainment purposes only. Always do your own due diligence before making any investment decisions. Past Reddit hype is not indicative of future price performance."
        ),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("FAQ")
                .font(.system(size: 10, weight: .black, design: .monospaced))
                .foregroundColor(.spTextDim)
                .tracking(1.5)
                .padding(.horizontal, 16)

            VStack(spacing: 8) {
                ForEach(items.indices, id: \.self) { i in
                    FAQItemView(question: items[i].question, answer: items[i].answer)
                }
            }
            .padding(.horizontal, 16)
        }
    }
}

// MARK: - Watchlist View

struct WatchlistView: View {
    @ObservedObject var vm: StockViewModel
    @StateObject private var purchases = PurchaseService.shared
    @State private var showAddSheet = false
    @State private var showPaywall = false
    @State private var editMode: EditMode = .inactive

    var body: some View {
        VStack(spacing: 0) {
            // ── Header ───────────────────────────────────────────────────
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("MY WATCHLIST")
                        .font(.system(size: 10, weight: .black, design: .monospaced))
                        .foregroundColor(.spTextDim)
                        .tracking(3)
                    HStack(alignment: .center, spacing: 8) {
                        Text("\(vm.watchlist.count) ticker\(vm.watchlist.count == 1 ? "" : "s")")
                            .font(.system(size: 22, weight: .black, design: .monospaced))
                            .foregroundColor(.spTextPrimary)
                        if !purchases.isPremium {
                            Text("\(vm.watchlist.count)/\(PurchaseService.freeWatchlistLimit)")
                                .font(.system(size: 11, weight: .bold, design: .monospaced))
                                .foregroundColor(vm.watchlist.count >= PurchaseService.freeWatchlistLimit ? .spReddit : .spTextDim)
                                .padding(.horizontal, 7)
                                .padding(.vertical, 3)
                                .background(Color.white.opacity(0.07))
                                .cornerRadius(6)
                        }
                    }
                }
                Spacer()
                HStack(spacing: 12) {
                    if !vm.watchlist.isEmpty {
                        Button(editMode == .active ? "Done" : "Reorder") {
                            withAnimation { editMode = editMode == .active ? .inactive : .active }
                        }
                        .font(.system(size: 12, weight: .bold, design: .monospaced))
                        .foregroundColor(.spTextSecondary)
                    }
                    Button {
                        if !purchases.isPremium && vm.watchlist.count >= PurchaseService.freeWatchlistLimit {
                            showPaywall = true
                        } else {
                            Analytics.capture("watchlist_add_sheet_opened")
                            showAddSheet = true
                        }
                    } label: {
                        ZStack(alignment: .topTrailing) {
                            Image(systemName: "plus.circle.fill")
                                .font(.system(size: 26))
                                .foregroundColor(.spAccentGreen)
                            if !purchases.isPremium && vm.watchlist.count >= PurchaseService.freeWatchlistLimit {
                                Image(systemName: "lock.fill")
                                    .font(.system(size: 10))
                                    .foregroundColor(.white)
                                    .padding(3)
                                    .background(Color.spReddit)
                                    .clipShape(Circle())
                                    .offset(x: 6, y: -4)
                            }
                        }
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 56)
            .padding(.bottom, 16)

            if vm.watchlist.isEmpty {
                // ── Empty state ──────────────────────────────────────────
                Spacer()
                VStack(spacing: 16) {
                    Text("🔖")
                        .font(.system(size: 48))
                    Text("Your watchlist is empty")
                        .font(.system(size: 17, weight: .bold, design: .monospaced))
                        .foregroundColor(.spTextSecondary)
                    Text("Track tickers you care about.\nGet notified when they trend on Reddit.")
                        .font(.system(size: 13, design: .serif))
                        .foregroundColor(.spTextDim)
                        .multilineTextAlignment(.center)
                        .lineSpacing(4)
                    Button { showAddSheet = true } label: {
                        Label("Add Your First Ticker", systemImage: "plus")
                            .font(.system(size: 14, weight: .bold, design: .monospaced))
                            .foregroundColor(.white)
                            .padding(.horizontal, 24)
                            .padding(.vertical, 12)
                            .background(Color.spAccentGreen)
                            .cornerRadius(10)
                    }
                }
                .padding(.horizontal, 32)
                Spacer()
            } else {
                // ── Watchlist items (List for drag-to-reorder & swipe-to-delete) ──
                List {
                    ForEach(vm.watchlist, id: \.self) { sym in
                        Group {
                            if let analysis = vm.allTickers.first(where: { $0.ticker == sym }) {
                                // Ticker is in current scan — show full card
                                TickerCardView(
                                    ticker: analysis,
                                    rank: (vm.watchlist.firstIndex(of: sym) ?? 0) + 1,
                                    isWatchlisted: true,
                                    onWatchlistToggle: { vm.removeFromWatchlist(sym) }
                                )
                            } else {
                                // Ticker not in current scan — placeholder
                                WatchlistPlaceholderCard(ticker: sym)
                            }
                        }
                        .buttonStyle(.plain)
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                        .listRowInsets(EdgeInsets(top: 5, leading: 16, bottom: 5, trailing: 16))
                    }
                    .onMove { vm.moveWatchlistItems(from: $0, to: $1) }
                    .onDelete { indices in
                        let syms = indices.map { vm.watchlist[$0] }
                        syms.forEach { vm.removeFromWatchlist($0) }
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                .environment(\.editMode, $editMode)
                // Push content above the custom tab bar (88pt height + safe area)
                .safeAreaInset(edge: .bottom) { Color.clear.frame(height: 88) }
            }
        }
        .background(Color.spBackground)
        .sheet(isPresented: $showAddSheet) {
            AddTickerSheet(vm: vm)
        }
        .sheet(isPresented: $showPaywall) {
            PaywallView()
        }
        .onReceive(vm.$showPaywall) { show in
            if show { showPaywall = true; vm.showPaywall = false }
        }
    }
}

// MARK: - Paywall View

struct PaywallView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var purchases = PurchaseService.shared
    @State private var isPurchasing = false
    @State private var isRestoring = false

    var body: some View {
        VStack(spacing: 0) {
            // drag handle
            RoundedRectangle(cornerRadius: 2)
                .fill(Color.white.opacity(0.2))
                .frame(width: 36, height: 4)
                .padding(.top, 12)
                .padding(.bottom, 24)

            Image(systemName: "lock.fill")
                .font(.system(size: 28))
                .foregroundColor(.spReddit)
                .padding(16)
                .background(Color.white.opacity(0.07))
                .cornerRadius(16)
                .padding(.bottom, 16)

            Text("Watchlist limit reached")
                .font(.system(size: 20, weight: .black, design: .monospaced))
                .foregroundColor(.spTextPrimary)
                .multilineTextAlignment(.center)
                .padding(.bottom, 6)

            Text("You've used all \(PurchaseService.freeWatchlistLimit) free slots.\nUpgrade to track unlimited tickers.")
                .font(.system(size: 13, design: .monospaced))
                .foregroundColor(.spTextSecondary)
                .multilineTextAlignment(.center)
                .padding(.bottom, 28)

            VStack(spacing: 12) {
                FeatureRow(text: "Unlimited watchlist tickers")
                FeatureRow(text: "Push alerts for every tracked ticker")
                FeatureRow(text: "One-time purchase, no subscription")
                FeatureRow(text: "Supports continued development")
            }
            .padding(.bottom, 32)

            Spacer()

            if let errorMsg = purchases.purchaseError {
                Text(errorMsg)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(.spReddit)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)
                    .padding(.bottom, 8)
            }

            Button {
                isPurchasing = true
                Task {
                    let success = await purchases.purchase()
                    isPurchasing = false
                    if success { dismiss() }
                }
            } label: {
                HStack {
                    if isPurchasing {
                        ProgressView().tint(.white).padding(.trailing, 4)
                    }
                    Text(isPurchasing ? "Processing…" : "Unlock for \(purchases.formattedPrice)")
                        .font(.system(size: 15, weight: .black, design: .monospaced))
                        .foregroundColor(.white)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 16)
                .background(Color.spReddit)
                .cornerRadius(12)
            }
            .disabled(isPurchasing || isRestoring)
            .padding(.horizontal, 24)
            .padding(.bottom, 10)

            // Grouped to stay under the ViewBuilder 10-child limit on Swift 5.7.
            Group {
                Text("One-time payment · No recurring charges")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(.spTextDim)
                    .padding(.bottom, 12)

                Button {
                    isRestoring = true
                    Task {
                        await purchases.restore()
                        isRestoring = false
                        if purchases.isPremium { dismiss() }
                    }
                } label: {
                    Text(isRestoring ? "Restoring…" : "Restore purchase")
                        .font(.system(size: 13, weight: .bold, design: .monospaced))
                        .foregroundColor(.spTextSecondary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.spCardBorder, lineWidth: 1))
                }
                .disabled(isPurchasing || isRestoring)
                .padding(.horizontal, 24)
                .padding(.bottom, 12)

                Text("Payment charged to your Apple ID. One-time non-consumable purchase. No recurring charges.")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(.spTextDim.opacity(0.6))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
                    .padding(.bottom, 32)
            }
        }
        .background(Color.spBackground)
    }
}

private struct FeatureRow: View {
    let text: String
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 18))
                .foregroundColor(.spAccentGreen)
            Text(text)
                .font(.system(size: 13, design: .monospaced))
                .foregroundColor(.spTextSecondary)
            Spacer()
        }
        .padding(.horizontal, 24)
    }
}

// MARK: - Watchlist Placeholder Card (ticker not in current scan)

struct WatchlistPlaceholderCard: View {
    let ticker: String

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(ticker)
                    .font(.system(size: 20, weight: .black, design: .monospaced))
                    .foregroundColor(.spTextDim)
                Text("Not in latest update")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(.spTextDim.opacity(0.6))
            }
            Spacer()
            if let url = URL(string: "https://finance.yahoo.com/quote/\(ticker)") {
                Link(destination: url) {
                    HStack(spacing: 5) {
                        Image(systemName: "chart.xyaxis.line")
                            .font(.system(size: 10))
                        Text("Yahoo Finance")
                            .font(.system(size: 10, weight: .semibold, design: .monospaced))
                        Image(systemName: "arrow.up.right.square")
                            .font(.system(size: 10))
                    }
                    .foregroundColor(.spAccentBlue)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(Color.spAccentBlue.opacity(0.08))
                    .cornerRadius(6)
                }
            }
        }
        .padding(14)
        .background(Color.spCard.opacity(0.5))
        .cornerRadius(14)
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.spCardBorder.opacity(0.5), lineWidth: 1))
    }
}

// MARK: - Add Ticker Sheet

struct AddTickerSheet: View {
    @ObservedObject var vm: StockViewModel
    @Environment(\.dismiss) var dismiss
    @State private var query = ""

    private var suggestions: [TickerAnalysis] {
        let q = query.uppercased()
        let base = vm.allTickers.filter { !vm.isInWatchlist($0.ticker) }
        guard !q.isEmpty else { return base }
        return base.filter { $0.ticker.contains(q) || $0.companyName.uppercased().contains(q) }
    }

    private var canAddManually: Bool {
        let q = query.uppercased()
        return !q.isEmpty && q.count <= 5 && !vm.isInWatchlist(q)
            && !suggestions.contains(where: { $0.ticker == q })
    }

    var body: some View {
        NavigationView {
            VStack(spacing: 0) {
                // Search field
                HStack(spacing: 10) {
                    Image(systemName: "magnifyingglass")
                        .foregroundColor(.spTextDim)
                    TextField("Search ticker or company…", text: $query)
                        .font(.system(size: 14, design: .monospaced))
                        .foregroundColor(.spTextPrimary)
                        .autocapitalization(.allCharacters)
                        .disableAutocorrection(true)
                    if !query.isEmpty {
                        Button { query = "" } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundColor(.spTextDim)
                        }
                    }
                }
                .padding(12)
                .background(Color.spCard)
                .cornerRadius(10)
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.spCardBorder, lineWidth: 1))
                .padding(.horizontal, 16)
                .padding(.top, 12)
                .padding(.bottom, 8)

                ScrollView {
                    LazyVStack(spacing: 8) {
                        // Manual add (if symbol not found in scan)
                        if canAddManually {
                            Button {
                                vm.addToWatchlist(query.uppercased())
                                dismiss()
                            } label: {
                                HStack(spacing: 10) {
                                    Image(systemName: "plus.circle.fill")
                                        .font(.system(size: 18))
                                        .foregroundColor(.spAccentGreen)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text("Track \(query.uppercased())")
                                            .font(.system(size: 14, weight: .bold, design: .monospaced))
                                            .foregroundColor(.spTextPrimary)
                                        Text("Add manually — data appears when it next trends")
                                            .font(.system(size: 11, design: .monospaced))
                                            .foregroundColor(.spTextDim)
                                    }
                                    Spacer()
                                }
                                .padding(14)
                                .background(Color.spAccentGreen.opacity(0.08))
                                .cornerRadius(10)
                                .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.spAccentGreen.opacity(0.2), lineWidth: 1))
                            }
                            .buttonStyle(.plain)
                        }

                        // Section header
                        if !suggestions.isEmpty {
                            HStack {
                                Text(query.isEmpty ? "TRENDING NOW" : "MATCHES")
                                    .font(.system(size: 9, weight: .black, design: .monospaced))
                                    .foregroundColor(.spTextDim)
                                    .tracking(1.5)
                                Spacer()
                            }
                            .padding(.top, 4)
                        }

                        // Scan suggestions
                        ForEach(suggestions) { t in
                            Button {
                                vm.addToWatchlist(t.ticker)
                                dismiss()
                            } label: {
                                HStack(spacing: 12) {
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(t.ticker)
                                            .font(.system(size: 16, weight: .black, design: .monospaced))
                                            .foregroundColor(.spTextPrimary)
                                        Text(t.companyName)
                                            .font(.system(size: 11, design: .monospaced))
                                            .foregroundColor(.spTextDim)
                                            .lineLimit(1)
                                    }
                                    Spacer()
                                    VStack(alignment: .trailing, spacing: 4) {
                                        Text("Score \(t.investmentScore)")
                                            .font(.system(size: 11, weight: .bold, design: .monospaced))
                                            .foregroundColor(.spAccentBlue)
                                        BadgeView(text: t.recommendation,
                                                  color: .recommendationColor(t.recommendation))
                                    }
                                }
                                .padding(12)
                                .background(Color.spCard)
                                .cornerRadius(10)
                                .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.spCardBorder, lineWidth: 1))
                            }
                            .buttonStyle(.plain)
                        }

                        if suggestions.isEmpty && !canAddManually && !query.isEmpty {
                            Text("No tickers match \"\(query.uppercased())\"")
                                .font(.system(size: 13, design: .monospaced))
                                .foregroundColor(.spTextDim)
                                .padding(.top, 32)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 32)
                }
            }
            .background(Color.spBackground.ignoresSafeArea())
            .navigationTitle("Add to Watchlist")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Cancel") { dismiss() }
                        .font(.system(size: 13, design: .monospaced))
                        .foregroundColor(.spTextSecondary)
                }
            }
        }
        .preferredColorScheme(.dark)
    }
}

// MARK: - Disclaimer

struct DisclaimerView: View {
    let onAccept: () -> Void

    @State private var hasScrolledToBottom = false
    @State private var showDeclineAlert = false

    var body: some View {
        ZStack {
            Color(hex: "0A0A0D").ignoresSafeArea()

            VStack(spacing: 0) {

                // ── Header ───────────────────────────────────────────────
                VStack(spacing: 8) {
                    Text("⚠️")
                        .font(.system(size: 36))
                        .padding(.top, 56)
                    Text("BEFORE YOU CONTINUE")
                        .font(.system(size: 11, weight: .black, design: .monospaced))
                        .foregroundColor(.spAccentOrange)
                        .tracking(2)
                    Text("Important Legal Disclosure")
                        .font(.system(size: 22, weight: .black, design: .monospaced))
                        .foregroundColor(.white)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 28)
                }
                .padding(.bottom, 20)

                // ── Scrollable legal text ─────────────────────────────────
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        disclaimerSection(
                            title: "NOT INVESTMENT ADVICE",
                            body: "StockPulse is an informational tool that aggregates and analyses publicly available sentiment data from Reddit communities. Nothing in this application constitutes financial, investment, legal, or tax advice of any kind. All content is provided for general informational and educational purposes only."
                        )
                        disclaimerSection(
                            title: "NO ADVISOR RELATIONSHIP",
                            body: "StockPulse is not a registered investment adviser, broker-dealer, financial planner, or fiduciary under any applicable law. Use of this application does not create any advisor-client, broker-client, or any other professional relationship between you and StockPulse or its creators."
                        )
                        disclaimerSection(
                            title: "ACCURACY OF INFORMATION",
                            body: "The data, scores, analysis, and recommendations displayed are generated by automated systems including artificial intelligence and sentiment analysis algorithms. This information:\n\n• May be inaccurate, incomplete, or significantly delayed\n• Is derived from unverified, anonymous, user-generated content\n• Does not account for all factors relevant to investment decisions\n• May reflect coordinated manipulation, misinformation, or speculation\n• Should never be the sole basis for any financial decision"
                        )
                        disclaimerSection(
                            title: "YOUR RESPONSIBILITY",
                            body: "By using StockPulse you acknowledge and agree that:\n\n• All investment and trading decisions are made solely at your own discretion and risk\n• You will conduct your own independent research and due diligence before acting on any information\n• You will consult a licensed financial professional before making investment decisions\n• You are solely responsible for evaluating the merits and risks of any investment\n• Past Reddit sentiment trends are not indicative of future stock price performance"
                        )
                        disclaimerSection(
                            title: "LIMITATION OF LIABILITY",
                            body: "To the fullest extent permitted by law, StockPulse, its creators, developers, contributors, and affiliates shall not be liable for any direct, indirect, incidental, special, consequential, punitive, or exemplary damages — including but not limited to financial losses, loss of profits, loss of data, or any other pecuniary loss — arising out of or related to your use of, or reliance on, any information provided by this application, even if advised of the possibility of such damages."
                        )
                        disclaimerSection(
                            title: "MARKET RISK",
                            body: "All investments carry risk. The value of stocks and other securities can decrease as well as increase, and you may receive back less than you invest. Speculative securities including small-cap and penny stocks discussed in Reddit communities may be highly volatile and illiquid, and investment in them may result in the total and permanent loss of capital."
                        )
                        disclaimerSection(
                            title: "REDDIT DATA",
                            body: "Content sourced from Reddit represents the personal opinions of anonymous internet users. StockPulse does not verify, endorse, or validate any such content. Reddit discussions may contain speculation, inaccurate information, exaggerated claims, and in some cases coordinated attempts to artificially inflate or deflate a security's price (\"pump and dump\" or \"short and distort\" schemes). StockPulse is not responsible for any such manipulation."
                        )
                        disclaimerSection(
                            title: "AI-GENERATED ANALYSIS",
                            body: "Investment scores, sentiment scores, risk assessments, and analyst summaries are generated by artificial intelligence and may contain errors, omissions, or hallucinations. AI analysis does not constitute a professional opinion and should not be treated as such."
                        )
                        disclaimerSection(
                            title: "NO WARRANTY",
                            body: "StockPulse is provided on an \"as is\" and \"as available\" basis without any warranty of any kind, express or implied, including but not limited to warranties of merchantability, fitness for a particular purpose, or non-infringement. We do not guarantee uninterrupted, timely, secure, or error-free operation of the application."
                        )

                        // Scroll sentinel
                        Color.clear
                            .frame(height: 1)
                            .onAppear { hasScrolledToBottom = true }
                    }
                    .padding(.horizontal, 20)
                    .padding(.bottom, 16)
                }
                .padding(.horizontal, 4)

                // ── Scroll nudge ─────────────────────────────────────────
                if !hasScrolledToBottom {
                    HStack(spacing: 5) {
                        Image(systemName: "chevron.down")
                            .font(.system(size: 10, weight: .bold))
                        Text("Scroll down to read the full disclosure")
                            .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    }
                    .foregroundColor(.spAccentOrange)
                    .padding(.vertical, 8)
                }

                // ── Buttons ───────────────────────────────────────────────
                VStack(spacing: 10) {
                    Button {
                        Analytics.capture("disclaimer_accepted")
                        onAccept()
                    } label: {
                        Text("I HAVE READ AND ACCEPT")
                            .font(.system(size: 14, weight: .black, design: .monospaced))
                            .foregroundColor(.white)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 16)
                            .background(hasScrolledToBottom ? Color.spAccentGreen : Color.spTextDim)
                            .cornerRadius(14)
                    }
                    .disabled(!hasScrolledToBottom)

                    Button {
                        showDeclineAlert = true
                    } label: {
                        Text("Decline")
                            .font(.system(size: 13, design: .monospaced))
                            .foregroundColor(.spTextDim)
                    }
                }
                .padding(.horizontal, 28)
                .padding(.bottom, 48)
                .padding(.top, 12)
            }
        }
        .alert("Cannot Continue", isPresented: $showDeclineAlert) {
            Button("OK", role: .cancel) { }
        } message: {
            Text("You must accept the disclaimer to use StockPulse. The app cannot be used without your acknowledgement of these terms.")
        }
    }

    @ViewBuilder
    private func disclaimerSection(title: String, body: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.system(size: 10, weight: .black, design: .monospaced))
                .foregroundColor(.spAccentOrange)
                .tracking(1.5)
            Text(body)
                .font(.system(size: 13, design: .monospaced))
                .foregroundColor(Color(hex: "888888"))
                .lineSpacing(4)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.white.opacity(0.03))
        .cornerRadius(10)
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color.white.opacity(0.06), lineWidth: 1)
        )
    }
}

// MARK: - Onboarding

private struct OnboardingSlide {
    let icon: String
    let tag: String
    let title: String
    let body: String
    let accent: Color
    let extra: AnyView?

    init(icon: String, tag: String, title: String, body: String,
         accent: Color, extra: AnyView? = nil) {
        self.icon = icon; self.tag = tag; self.title = title
        self.body = body; self.accent = accent; self.extra = extra
    }
}

struct OnboardingView: View {
    let onFinish: () -> Void
    @State private var page = 0

    private let slides: [OnboardingSlide] = [
        OnboardingSlide(
            icon: "📡",
            tag: "WELCOME",
            title: "StockPulse",
            body: "Reddit's pulse on the stock market — real-time sentiment analysis powered by AI.",
            accent: .spReddit
        ),
        OnboardingSlide(
            icon: "🔍",
            tag: "HOW IT WORKS",
            title: "5 Sources, Updated Every 15 Minutes",
            body: "StockPulse monitors Reddit, StockTwits, Google Trends, financial news, and SEC insider filings — every 15 minutes. Tickers are validated against Yahoo Finance and ranked by AI.",
            accent: .spAccentBlue
        ),
        OnboardingSlide(
            icon: "🤖",
            tag: "AI ANALYSIS",
            title: "Scores Powered by Claude AI",
            body: "The top trending tickers get a 1–100 Investment Score and Sentiment Score — generated by AI after weighing Reddit momentum, price action, volume spikes, and risk signals.",
            accent: .spAccentPurple,
            extra: AnyView(
                HStack(spacing: 16) {
                    VStack(spacing: 4) {
                        Text("74")
                            .font(.system(size: 22, weight: .black, design: .monospaced))
                            .foregroundColor(.spAccentBlue)
                        Text("INVEST")
                            .font(.system(size: 9, weight: .bold, design: .monospaced))
                            .foregroundColor(.spTextDim)
                    }
                    .frame(width: 60, height: 60)
                    .background(Color.spAccentBlue.opacity(0.08))
                    .cornerRadius(12)

                    VStack(spacing: 4) {
                        Text("82")
                            .font(.system(size: 22, weight: .black, design: .monospaced))
                            .foregroundColor(.spAccentGreen)
                        Text("SNTMT")
                            .font(.system(size: 9, weight: .bold, design: .monospaced))
                            .foregroundColor(.spTextDim)
                    }
                    .frame(width: 60, height: 60)
                    .background(Color.spAccentGreen.opacity(0.08))
                    .cornerRadius(12)
                }
            )
        ),
        OnboardingSlide(
            icon: "📊",
            tag: "RECOMMENDATIONS",
            title: "Four Clear Signals",
            body: "Every ticker gets one of four AI recommendations based on Reddit sentiment and price data.",
            accent: .spAccentYellow,
            extra: AnyView(
                VStack(spacing: 8) {
                    ForEach([
                        ("BUY",         "Strong bullish momentum",         Color.spAccentGreen),
                        ("WATCH",       "Interesting but wait for more",   Color.spAccentYellow),
                        ("AVOID",       "Bearish signals or too risky",    Color.spAccentRed),
                        ("SHORT WATCH", "Trending downward on Reddit",     Color.spAccentOrange),
                    ], id: \.0) { label, desc, color in
                        HStack(spacing: 12) {
                            Text(label)
                                .font(.system(size: 11, weight: .black, design: .monospaced))
                                .foregroundColor(color)
                                .frame(width: 90, alignment: .leading)
                            Text(desc)
                                .font(.system(size: 12, design: .monospaced))
                                .foregroundColor(.spTextSecondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(14)
                .background(Color.white.opacity(0.04))
                .cornerRadius(12)
            )
        ),
        OnboardingSlide(
            icon: "🚀",
            tag: "ALL SET",
            title: "You're Ready",
            body: "Check the Radar tab to see what Reddit is buzzing about right now. Tap any ticker for the full AI breakdown.",
            accent: .spAccentGreen
        ),
    ]

    var body: some View {
        ZStack {
            Color(hex: "0A0A0D").ignoresSafeArea()

            VStack(spacing: 0) {

                // Skip button
                HStack {
                    Spacer()
                    if page < slides.count - 1 {
                        Button("Skip") {
                            Analytics.capture("onboarding_skipped", ["from_slide": page])
                            onFinish()
                        }
                            .font(.system(size: 13, weight: .semibold, design: .monospaced))
                            .foregroundColor(.spTextDim)
                            .padding(.horizontal, 20)
                            .padding(.vertical, 14)
                    }
                }

                // Slides
                TabView(selection: $page) {
                    ForEach(slides.indices, id: \.self) { i in
                        slideContent(slides[i])
                            .tag(i)
                    }
                }
                .tabViewStyle(.page(indexDisplayMode: .never))
                .animation(.easeInOut, value: page)
                .onChange(of: page) { slide in
                    Analytics.capture("onboarding_slide_viewed", ["slide": slide])
                }

                // Page dots + button
                VStack(spacing: 28) {
                    // Dots
                    HStack(spacing: 7) {
                        ForEach(slides.indices, id: \.self) { i in
                            Capsule()
                                .fill(i == page ? slides[page].accent : Color.white.opacity(0.15))
                                .frame(width: i == page ? 20 : 7, height: 7)
                                .animation(.easeInOut(duration: 0.25), value: page)
                        }
                    }

                    // Next / Get Started button
                    Button {
                        if page < slides.count - 1 {
                            withAnimation { page += 1 }
                        } else {
                            Analytics.capture("onboarding_completed")
                            onFinish()
                        }
                    } label: {
                        Text(page < slides.count - 1 ? "NEXT" : "GET STARTED")
                            .font(.system(size: 15, weight: .black, design: .monospaced))
                            .foregroundColor(.white)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 16)
                            .background(slides[page].accent)
                            .cornerRadius(14)
                    }
                    .padding(.horizontal, 28)
                }
                .padding(.bottom, 48)
            }
        }
    }

    @ViewBuilder
    private func slideContent(_ slide: OnboardingSlide) -> some View {
        VStack(spacing: 0) {
            Spacer()

            // Icon
            Text(slide.icon)
                .font(.system(size: 64))
                .padding(.bottom, 24)

            // Tag
            Text(slide.tag)
                .font(.system(size: 10, weight: .black, design: .monospaced))
                .foregroundColor(slide.accent)
                .tracking(2)
                .padding(.bottom, 12)

            // Title
            Text(slide.title)
                .font(.system(size: 26, weight: .black, design: .monospaced))
                .foregroundColor(.white)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 28)
                .padding(.bottom, 16)

            // Body
            Text(slide.body)
                .font(.system(size: 15, design: .serif))
                .foregroundColor(Color(hex: "888888"))
                .multilineTextAlignment(.center)
                .lineSpacing(5)
                .padding(.horizontal, 32)

            // Extra content (score boxes, recommendation table)
            if let extra = slide.extra {
                extra
                    .padding(.horizontal, 28)
                    .padding(.top, 28)
            }

            Spacer()
            Spacer()
        }
    }
}
