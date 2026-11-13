// NotificationService.swift
// StockPulse — Manages iOS push notifications and background app refresh

import Foundation
import UserNotifications
import BackgroundTasks
import UIKit

// MARK: - Background Task Identifier
// Register this in Info.plist under BGTaskSchedulerPermittedIdentifiers
let kBGRefreshTaskID = "com.yourname.StockPulse.refresh"

final class NotificationService: NSObject, ObservableObject, UNUserNotificationCenterDelegate {

    static let shared = NotificationService()
    private let center = UNUserNotificationCenter.current()

    @Published var authorizationStatus: UNAuthorizationStatus = .notDetermined
    @Published var deviceToken: String?

    override private init() {
        super.init()
        center.delegate = self
    }

    // MARK: - Request Permission

    func requestAuthorization() async -> Bool {
        do {
            let granted = try await center.requestAuthorization(options: [.alert, .sound, .badge])
            await MainActor.run { self.authorizationStatus = granted ? .authorized : .denied }
            if granted {
                await MainActor.run { UIApplication.shared.registerForRemoteNotifications() }
            }
            return granted
        } catch {
            print("Notification auth error: \(error)")
            return false
        }
    }

    // MARK: - Device Token Registration

    func handleDeviceToken(_ tokenData: Data) {
        let token = tokenData.map { String(format: "%02x", $0) }.joined()
        self.deviceToken = token
        print("APNs device token: \(token)")

        Task {
            do {
                let sandbox = !isProductionBuild()
                try await APIService.shared.registerDevice(token: token, sandbox: sandbox)
                print("Device token registered with backend")
                // Re-sync watchlist immediately so the backend has it even after
                // a redeploy that wiped the in-memory watchlist store.
                if let watchlist = UserDefaults.standard.stringArray(forKey: "watchlist"),
                   !watchlist.isEmpty {
                    try? await APIService.shared.updateWatchlist(token: token, tickers: watchlist)
                    print("Watchlist re-synced: \(watchlist)")
                }
            } catch {
                print("Device token registration failed: \(error)")
            }
        }
    }

    func handleRegistrationError(_ error: Error) {
        print("APNs registration error: \(error)")
    }

    // MARK: - Local Notifications (fallback when app is open)

    func scheduleLocalScanAlert(analyses: [TickerAnalysis]) {
        let top = analyses.first
        let bearishCount = analyses.filter { $0.negativeTraction }.count
        let bullishCount = analyses.filter { !$0.negativeTraction }.count

        let content = UNMutableNotificationContent()
        content.title = "📡 Reddit Scan Complete"
        content.sound = .default

        if let top = top {
            content.body = "🚀 #1 \(top.ticker) (Score \(top.investmentScore)) · \(bullishCount) bullish · \(bearishCount) bearish ⚠"
        } else {
            content.body = "Scan complete — \(analyses.count) tickers analyzed"
        }

        content.badge = bullishCount as NSNumber
        content.userInfo = [
            "scan_type": "15min",
            "top_ticker": top?.ticker ?? "",
            "top_score": top?.investmentScore ?? 0,
            "bearish_count": bearishCount,
        ]

        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 0.1, repeats: false)
        let request = UNNotificationRequest(
            identifier: "scan_\(Date().timeIntervalSince1970)",
            content: content,
            trigger: trigger
        )

        center.add(request) { error in
            if let error { print("Local notification error: \(error)") }
        }
    }

    func scheduleWatchlistAlert(ticker: String, postTitle: String?) {
        Task {
            // Ensure permission is granted before scheduling
            let settings = await center.notificationSettings()
            guard settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional else {
                // Request permission if not yet determined
                if settings.authorizationStatus == .notDetermined {
                    _ = await requestAuthorization()
                }
                return
            }

            let content = UNMutableNotificationContent()
            content.title = "📌 $\(ticker) appeared in latest scan"
            content.body = postTitle ?? "\(ticker) has new Reddit activity — check your Watchlist"
            content.sound = .default
            content.userInfo = ["type": "watchlist_alert", "ticker": ticker]

            let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 1.0, repeats: false)
            let request = UNNotificationRequest(
                identifier: "watchlist_\(ticker)_\(Int(Date().timeIntervalSince1970))",
                content: content,
                trigger: trigger
            )
            do {
                try await center.add(request)
            } catch {
                print("Watchlist notification error: \(error)")
            }
        }
    }

    func scheduleRedFlagAlert(ticker: TickerAnalysis) {
        let content = UNMutableNotificationContent()
        content.title = "🚨 Red Flag: $\(ticker.ticker)"
        content.body = "Unusual activity detected · Score \(ticker.investmentScore) · \(ticker.riskLevel) risk"
        content.sound = UNNotificationSound(named: UNNotificationSoundName("alert.caf"))

        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 0.1, repeats: false)
        let request = UNNotificationRequest(
            identifier: "redflag_\(ticker.ticker)",
            content: content,
            trigger: trigger
        )
        center.add(request)
    }

    // MARK: - Badge Management

    func clearBadge() {
        Task { @MainActor in
            UIApplication.shared.applicationIconBadgeNumber = 0
        }
    }

    // MARK: - Background App Refresh Registration

    func registerBackgroundTasks() {
        BGTaskScheduler.shared.register(
            forTaskWithIdentifier: kBGRefreshTaskID,
            using: nil
        ) { task in
            self.handleBackgroundRefresh(task: task as! BGAppRefreshTask)
        }
    }

    func scheduleBackgroundRefresh() {
        let request = BGAppRefreshTaskRequest(identifier: kBGRefreshTaskID)
        request.earliestBeginDate = Date(timeIntervalSinceNow: 15 * 60) // 15 minutes

        do {
            try BGTaskScheduler.shared.submit(request)
            print("Background refresh scheduled for 15 min")
        } catch {
            print("Background refresh scheduling failed: \(error)")
        }
    }

    private func handleBackgroundRefresh(task: BGAppRefreshTask) {
        // Schedule next refresh immediately
        scheduleBackgroundRefresh()

        let taskOperation = Task {
            do {
                let result = try await APIService.shared.fetchLatestScan()
                // Fire local notification with results
                scheduleLocalScanAlert(analyses: result.results)
                task.setTaskCompleted(success: true)
            } catch {
                print("Background refresh failed: \(error)")
                task.setTaskCompleted(success: false)
            }
        }

        task.expirationHandler = {
            taskOperation.cancel()
        }
    }

    // MARK: - UNUserNotificationCenterDelegate

    /// Show notification even when app is in foreground
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound, .badge])
    }

    /// Handle tap on notification
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let userInfo = response.notification.request.content.userInfo
        if let type = userInfo["type"] as? String, type == "watchlist_alert",
           let ticker = userInfo["ticker"] as? String {
            NotificationCenter.default.post(
                name: .didTapWatchlistNotification,
                object: nil,
                userInfo: ["ticker": ticker]
            )
        } else if let topTicker = userInfo["top_ticker"] as? String, !topTicker.isEmpty {
            NotificationCenter.default.post(
                name: .didTapScanNotification,
                object: nil,
                userInfo: ["ticker": topTicker]
            )
        }
        completionHandler()
    }

    // MARK: - Helpers

    private func isProductionBuild() -> Bool {
        #if DEBUG
        return false
        #else
        return true
        #endif
    }
}

// MARK: - Notification Names
extension Notification.Name {
    static let didTapScanNotification     = Notification.Name("didTapScanNotification")
    static let didTapWatchlistNotification = Notification.Name("didTapWatchlistNotification")
    static let switchToWatchlistTab        = Notification.Name("switchToWatchlistTab")
}
