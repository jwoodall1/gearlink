import SwiftUI
import UIKit

// Shared semantic colors follow the app's System / Light / Dark preference.
enum Brand {
    static let blue = adaptive(light: 0x0062FF, dark: 0x6AA5FF)
    static let ink = adaptive(light: 0x122442, dark: 0xE8EFFB)
    static let paper = adaptive(light: 0xF4F7FC, dark: 0x101724)
    static let soft = adaptive(light: 0xEDF4FF, dark: 0x203454)
    static let line = adaptive(light: 0xDFE7F3, dark: 0x34445C)
    static let card = adaptive(light: 0xFFFFFF, dark: 0x1B2638)

    private static func adaptive(light: UInt32, dark: UInt32) -> Color {
        Color(uiColor: UIColor { traits in
            let hex = traits.userInterfaceStyle == .dark ? dark : light
            return UIColor(red: CGFloat((hex >> 16) & 255) / 255,
                           green: CGFloat((hex >> 8) & 255) / 255,
                           blue: CGFloat(hex & 255) / 255, alpha: 1)
        })
    }
}

extension View {
    func gearPanel() -> some View {
        padding(20).frame(maxWidth: .infinity, alignment: .leading)
            .background(Brand.card, in: RoundedRectangle(cornerRadius: 16))
            .overlay(RoundedRectangle(cornerRadius: 16).stroke(Brand.line, lineWidth: 1))
    }
}

struct MetricTile: View {
    let title: String
    let value: Int
    let icon: String
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Image(systemName: icon).foregroundStyle(Brand.blue).accessibilityHidden(true)
            Text(value, format: .number).font(.largeTitle.bold())
            Text(title).font(.subheadline).foregroundStyle(.secondary)
        }.gearPanel().frame(maxHeight: .infinity, alignment: .top)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(title), \(value)")
    }
}

struct WorkspaceMessage: View {
    let title: String
    let message: String
    var icon = "tray"
    var retry: (() -> Void)? = nil
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(title, systemImage: icon).font(.headline)
            Text(message).font(.subheadline).foregroundStyle(.secondary)
            if let retry {
                Button("Try again", action: retry).buttonStyle(.bordered).frame(minHeight: 44)
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct AthleteSummaryRow: View {
    let athlete: Athlete
    let editable: Bool
    var body: some View {
        HStack(spacing: 12) {
            Text(athlete.initials).font(.caption.bold()).foregroundStyle(Brand.blue)
                .frame(width: 40, height: 40).background(Brand.soft, in: Circle())
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 5) {
                Text(athlete.name).font(.headline).foregroundStyle(Brand.ink)
                Text(athlete.team.flatMap { $0.isEmpty ? nil : $0 } ?? "No team")
                    .font(.subheadline).foregroundStyle(.secondary)
                if !athlete.active { Text("Inactive").font(.caption).foregroundStyle(.secondary) }
            }
            Spacer(minLength: 0)
            if editable { Image(systemName: "pencil").foregroundStyle(Brand.blue).accessibilityHidden(true) }
        }.padding(.vertical, 6).frame(minHeight: 44)
    }
}
