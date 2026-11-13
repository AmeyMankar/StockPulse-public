// CrashReporter.swift
// StockPulse — Thin Sentry wrapper for crash reporting and error tracking.
//
// ── HOW TO ACTIVATE (one-time Xcode setup) ───────────────────────────────────
// 1. In Xcode: File → Add Package Dependencies
// 2. Paste URL: https://github.com/getsentry/sentry-cocoa
// 3. Choose version rule: Up to Next Major, starting from 8.0.0
// 4. Add "Sentry" library to the StockPulse target
// 5. In Info.plist add two string keys:
//      SentryDSN         = <your iOS project DSN from sentry.io>
//      SentryEnvironment = production          (or staging / development)
//
// Without the package, all calls are graceful no-ops — the app compiles and
// runs normally. Add the package at any time to activate reporting.
// ─────────────────────────────────────────────────────────────────────────────

import Foundation

#if canImport(Sentry)
import Sentry
#endif

/// Severity level for manual event captures.
enum ReportLevel {
    case debug, info, warning, error, fatal
}

final class CrashReporter {
    static let shared = CrashReporter()
    private init() {}

    // MARK: - Configuration

    /// Call once at app launch (before any UI is shown).
    /// Reads DSN and environment from Info.plist — no hardcoded secrets.
    func configure() {
#if canImport(Sentry)
        let dsn = Bundle.main.object(forInfoDictionaryKey: "SentryDSN") as? String ?? ""
        guard !dsn.isEmpty else {
            print("[CrashReporter] SentryDSN not found in Info.plist — add it to enable reporting")
            return
        }
        let env = Bundle.main.object(forInfoDictionaryKey: "SentryEnvironment") as? String
            ?? "production"

        SentrySDK.start { options in
            options.dsn                   = dsn
            options.environment           = env
            options.enableCrashHandler    = true     // native crash reporting
            options.enableSwizzling       = true     // auto-instrument UIKit lifecycle
            options.tracesSampleRate      = 0.1      // 10 % of sessions → performance insights
            options.attachScreenshot      = true     // screenshot on crash for context
            options.attachViewHierarchy   = true
            options.sendDefaultPii        = false    // GDPR-safe: no emails / IPs
        }
        print("[CrashReporter] Sentry initialized (env: \(env))")
#else
        print("[CrashReporter] Sentry SDK not installed. Add the package to activate.")
#endif
    }

    // MARK: - Error Capture

    /// Capture a Swift Error (e.g. an APIError from a failed network call).
    func capture(error: Error, context: [String: Any] = [:]) {
#if canImport(Sentry)
        SentrySDK.capture(error: error) { scope in
            context.forEach { scope.setExtra(value: $1, key: $0) }
        }
#else
        print("[CrashReporter] Error (not reported): \(error.localizedDescription)")
#endif
    }

    /// Capture a plain message — useful for non-fatal warnings.
    func capture(message: String, level: ReportLevel = .error, context: [String: Any] = [:]) {
#if canImport(Sentry)
        SentrySDK.capture(message: message) { scope in
            scope.setLevel(level.asSentryLevel)
            context.forEach { scope.setExtra(value: $1, key: $0) }
        }
#else
        print("[CrashReporter] [\(level)] \(message)")
#endif
    }

    /// Add a navigation/action breadcrumb shown in the Sentry event timeline.
    func breadcrumb(_ message: String, category: String = "app") {
#if canImport(Sentry)
        let crumb      = Breadcrumb()
        crumb.message  = message
        crumb.category = category
        crumb.level    = .info
        SentrySDK.addBreadcrumb(crumb)
#endif
    }
}

// MARK: - ReportLevel → SentryLevel (only compiled when Sentry is present)

#if canImport(Sentry)
private extension ReportLevel {
    var asSentryLevel: SentryLevel {
        switch self {
        case .debug:   return .debug
        case .info:    return .info
        case .warning: return .warning
        case .error:   return .error
        case .fatal:   return .fatal
        }
    }
}
#endif
