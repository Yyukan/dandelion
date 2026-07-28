//
//  TerminalTheme.swift
//  Dandelion
//
//  Fixed dark, monospace, azure-accent design tokens for the status panel.
//  Intentionally not adaptive to system light/dark mode.
//

import SwiftUI

/// Centralized design tokens for Dandelion's custom "terminal" theme.
enum TerminalTheme {

    // MARK: Colors

    enum Colors {
        static let background = Color(red: 0.043, green: 0.051, blue: 0.067)
        static let surface = Color(red: 0.071, green: 0.082, blue: 0.106)
        static let surfaceElevated = Color(red: 0.098, green: 0.112, blue: 0.145)
        static let border = Color.white.opacity(0.08)

        static let accent = Color(red: 0.310, green: 0.635, blue: 0.980) // azure blue
        static let accentDim = Color(red: 0.310, green: 0.635, blue: 0.980).opacity(0.35)

        static let textPrimary = Color(white: 0.94)
        static let textSecondary = Color(white: 0.62)
        static let textTertiary = Color(white: 0.42)

        static let warning = Color(red: 0.93, green: 0.71, blue: 0.31)
        static let danger = Color(red: 0.87, green: 0.36, blue: 0.36)
    }

    // MARK: Fonts

    enum Fonts {
        static func mono(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
            .system(size: size, weight: weight, design: .monospaced)
        }

        static let title = mono(15, weight: .semibold)
        static let heading = mono(12, weight: .semibold)
        static let body = mono(12, weight: .regular)
        static let caption = mono(10, weight: .regular)
        static let metric = mono(20, weight: .bold)
    }

    // MARK: Spacing

    enum Spacing {
        static let xs: CGFloat = 4
        static let sm: CGFloat = 8
        static let md: CGFloat = 12
        static let lg: CGFloat = 16
        static let xl: CGFloat = 24
    }

    // MARK: Metrics

    enum Metrics {
        static let panelWidth: CGFloat = 360
        static let cornerRadius: CGFloat = 12
        static let cardCornerRadius: CGFloat = 10
    }
}
