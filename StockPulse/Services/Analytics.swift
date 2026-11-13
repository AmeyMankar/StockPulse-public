// Analytics.swift
// Thin wrapper around PostHog — all event capture goes through here.
//
// ── HOW TO ACTIVATE (one-time Xcode setup) ───────────────────────────────────
// 1. In Xcode: File → Add Package Dependencies
// 2. Paste URL: https://github.com/PostHog/posthog-ios
// 3. Choose version rule: Up to Next Major, starting from 3.0.0 (needs Xcode 15+)
// 4. Add "PostHog" library to the StockPulse target
// 5. Replace the no-op bodies below with the real PostHogSDK calls.
//
// Without the package, all calls are no-ops — the app compiles and runs
// normally. Add the package at any time to activate analytics.
// ─────────────────────────────────────────────────────────────────────────────

import Foundation

enum Analytics {

    static func setup() {
        print("[Analytics] PostHog SDK not installed. Add the package to activate.")
    }

    static func capture(_ event: String, _ properties: [String: Any] = [:]) {
        print("[Analytics] \(event) (not captured): \(properties)")
    }
}
