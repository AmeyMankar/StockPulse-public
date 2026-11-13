// StockPulseApp.swift
// StockPulse — App entry point, handles APNs + background tasks

import SwiftUI
import BackgroundTasks
import UserNotifications

@main
struct StockPulseApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}

// MARK: - App Delegate

class AppDelegate: NSObject, UIApplicationDelegate {

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {

        // 1. Analytics — before everything so launch event is captured
        Analytics.setup()
        Analytics.capture("app_launched")

        // 2. Crash reporting
        CrashReporter.shared.configure()

        // 3. Register background task handler BEFORE the app finishes launching
        NotificationService.shared.registerBackgroundTasks()

        // 4. Request notification permission, then always re-register token
        //    so the backend recovers its device list after any restart/redeploy.
        Task {
            let granted = await NotificationService.shared.requestAuthorization()
            if granted {
                NotificationService.shared.scheduleBackgroundRefresh()
            }
        }
        // Force APNs to call didRegisterForRemoteNotificationsWithDeviceToken on every
        // launch — iOS returns the cached token immediately, which re-populates the backend.
        UIApplication.shared.registerForRemoteNotifications()

        return true
    }

    // MARK: - APNs Token Registration

    func application(
        _ application: UIApplication,
        didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
    ) {
        NotificationService.shared.handleDeviceToken(deviceToken)
    }

    func application(
        _ application: UIApplication,
        didFailToRegisterForRemoteNotificationsWithError error: Error
    ) {
        NotificationService.shared.handleRegistrationError(error)
    }

    // MARK: - Remote Notification Received (background/foreground)

    func application(
        _ application: UIApplication,
        didReceiveRemoteNotification userInfo: [AnyHashable: Any],
        fetchCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void
    ) {
        // Triggered when APNs delivers a notification with content-available: 1
        Task {
            do {
                let scan = try await APIService.shared.fetchLatestScan()
                // Schedule a local notification with the results
                NotificationService.shared.scheduleLocalScanAlert(analyses: scan.results)
                completionHandler(.newData)
            } catch {
                completionHandler(.failed)
            }
        }
    }

    // MARK: - App Lifecycle

    func applicationDidEnterBackground(_ application: UIApplication) {
        // Re-schedule background refresh when app backgrounds
        NotificationService.shared.scheduleBackgroundRefresh()
    }
}
