// DesignSystem.swift
// StockPulse — Colors, fonts, and reusable UI components

import SwiftUI
import UIKit

extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

// MARK: - UIColor hex helper (used inside adaptive closures)

private extension UIColor {
    convenience init(hex: String) {
        let h = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int: UInt64 = 0
        Scanner(string: h).scanHexInt64(&int)
        self.init(
            red:   CGFloat((int >> 16) & 0xFF) / 255,
            green: CGFloat((int >> 8)  & 0xFF) / 255,
            blue:  CGFloat(int         & 0xFF) / 255,
            alpha: 1
        )
    }
}

// MARK: - Color Palette

extension Color {

    // Resolves at render time against the active colour scheme — no environment needed.
    private static func adaptive(dark: String, light: String) -> Color {
        Color(UIColor { tc in
            tc.userInterfaceStyle == .dark ? UIColor(hex: dark) : UIColor(hex: light)
        })
    }

    // Surface & text — flip with theme
    static let spBackground    = adaptive(dark: "0A0A0D", light: "FFFFFF")
    static let spCard          = adaptive(dark: "111116", light: "F2F2F7")
    static let spCardBorder    = adaptive(dark: "1E1E26", light: "DDDDE6")
    static let spTextPrimary   = adaptive(dark: "FFFFFF", light: "0A0A0D")
    static let spTextSecondary = adaptive(dark: "888888", light: "55555A")
    static let spTextDim       = adaptive(dark: "444444", light: "AAAABC")

    // Accent colours — identical in both modes
    static let spAccentGreen   = Color(hex: "00E676")
    static let spAccentRed     = Color(hex: "FF1744")
    static let spAccentOrange  = Color(hex: "FF6D00")
    static let spAccentBlue    = Color(hex: "2979FF")
    static let spAccentYellow  = Color(hex: "FFC400")
    static let spAccentPurple  = Color(hex: "AA00FF")
    static let spReddit        = Color(hex: "FF4500")

    // Sub colours
    static let spWSB       = Color(hex: "FF4500")
    static let spStocks    = Color(hex: "00C853")
    static let spPenny     = Color(hex: "FFD600")
    static let spStockMkt  = Color(hex: "2979FF")
    static let spStonks    = Color(hex: "AA00FF")

    init(hex: String) {
        let h = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int: UInt64 = 0
        Scanner(string: h).scanHexInt64(&int)
        let r = Double((int >> 16) & 0xFF) / 255
        let g = Double((int >> 8)  & 0xFF) / 255
        let b = Double(int         & 0xFF) / 255
        self.init(red: r, green: g, blue: b)
    }

    static func subColor(_ sub: String) -> Color {
        switch sub {
        case "wallstreetbets":   return .spWSB
        case "stocks":           return .spStocks
        case "pennystocks":      return .spPenny
        case "stockmarket":      return .spStockMkt
        case "stockstobuytoday": return .spStonks
        default:                 return .spTextSecondary
        }
    }

    static func riskColor(_ risk: String) -> Color {
        switch risk {
        case "Low":     return .spAccentGreen
        case "Medium":  return .spAccentYellow
        case "High":    return .spAccentOrange
        case "Extreme": return .spAccentRed
        default:        return .spTextSecondary
        }
    }

    static func recommendationColor(_ rec: String) -> Color {
        switch rec {
        case "BUY":         return .spAccentGreen
        case "WATCH":       return .spAccentYellow
        case "AVOID":       return .spAccentRed
        case "SHORT_WATCH": return .spAccentOrange
        default:            return .spTextSecondary
        }
    }
}

// MARK: - Score Ring View

struct ScoreRingView: View {
    let score: Int
    let label: String
    let color: Color
    var size: CGFloat = 56

    private var progress: Double { Double(score) / 100.0 }

    var body: some View {
        VStack(spacing: 4) {
            ZStack {
                Circle()
                    .stroke(Color.spCardBorder, lineWidth: 4)
                Circle()
                    .trim(from: 0, to: progress)
                    .stroke(color, style: StrokeStyle(lineWidth: 4, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(.easeInOut(duration: 0.8), value: score)
                Text("\(score)")
                    .font(.system(size: size * 0.26, weight: .black, design: .monospaced))
                    .foregroundColor(color)
            }
            .frame(width: size, height: size)
            Text(label)
                .font(.system(size: 9, weight: .bold, design: .monospaced))
                .foregroundColor(.spTextDim)
        }
    }
}

// MARK: - Badge View

struct BadgeView: View {
    let text: String
    let color: Color
    var filled: Bool = false

    var body: some View {
        Text(text)
            .font(.system(size: 10, weight: .heavy, design: .monospaced))
            .foregroundColor(filled ? .black : color)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(filled ? color : color.opacity(0.15))
            .cornerRadius(4)
    }
}

// MARK: - Subreddit Pill

struct SubredditPill: View {
    let sub: String
    let count: Int

    var body: some View {
        HStack(spacing: 3) {
            Circle()
                .fill(Color.subColor(sub))
                .frame(width: 5, height: 5)
            Text("r/\(sub)")
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .foregroundColor(Color.subColor(sub))
            Text("·\(count)")
                .font(.system(size: 10, design: .monospaced))
                .foregroundColor(.spTextDim)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Color.subColor(sub).opacity(0.1))
        .cornerRadius(6)
    }
}

// MARK: - Section Header

struct SectionHeaderView: View {
    let title: String
    let count: Int
    let color: Color

    var body: some View {
        HStack {
            Rectangle()
                .fill(color)
                .frame(width: 3, height: 14)
                .cornerRadius(2)
            Text(title)
                .font(.system(size: 13, weight: .black, design: .monospaced))
                .foregroundColor(.spTextPrimary)
                .tracking(1.5)
            Spacer()
            Text("\(count)")
                .font(.system(size: 12, weight: .bold, design: .monospaced))
                .foregroundColor(color)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }
}

// MARK: - Empty State

struct EmptyStateView: View {
    let icon: String
    let message: String

    var body: some View {
        VStack(spacing: 12) {
            Text(icon).font(.system(size: 40))
            Text(message)
                .font(.system(size: 14, design: .serif))
                .foregroundColor(.spTextSecondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(40)
    }
}

// MARK: - Loading Spinner

struct SpinnerView: View {
    @State private var rotation = 0.0

    var body: some View {
        Circle()
            .trim(from: 0.1, to: 0.9)
            .stroke(Color.spReddit, style: StrokeStyle(lineWidth: 3, lineCap: .round))
            .frame(width: 40, height: 40)
            .rotationEffect(.degrees(rotation))
            .onAppear {
                withAnimation(.linear(duration: 1).repeatForever(autoreverses: false)) {
                    rotation = 360
                }
            }
    }
}

// MARK: - FAQ Item (expandable accordion)

struct FAQItemView: View {
    let question: String
    let answer: String
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) { expanded.toggle() }
            } label: {
                HStack(alignment: .top, spacing: 12) {
                    Text(question)
                        .font(.system(size: 13, weight: .semibold, design: .monospaced))
                        .foregroundColor(.spTextPrimary)
                        .multilineTextAlignment(.leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundColor(.spTextDim)
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                        .padding(.top, 2)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 13)
            }

            if expanded {
                Text(answer)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundColor(.spTextSecondary)
                    .lineSpacing(4)
                    .padding(.horizontal, 14)
                    .padding(.bottom, 14)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .background(Color.spCard)
        .cornerRadius(10)
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color.spCardBorder, lineWidth: 1)
        )
    }
}

// MARK: - Stat Box

struct StatBoxView: View {
    let label: String
    let value: String
    let color: Color

    var body: some View {
        VStack(spacing: 3) {
            Text(value)
                .font(.system(size: 15, weight: .black, design: .monospaced))
                .foregroundColor(color)
            Text(label)
                .font(.system(size: 9, weight: .semibold, design: .monospaced))
                .foregroundColor(.spTextDim)
                .tracking(0.5)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10)
        .background(color.opacity(0.07))
        .cornerRadius(8)
    }
}
