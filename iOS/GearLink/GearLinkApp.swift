import SwiftUI

enum AppAppearance: String, CaseIterable, Identifiable {
    case system, light, dark

    var id: String { rawValue }
    var title: String {
        switch self {
        case .system: return "System"
        case .light: return "Light"
        case .dark: return "Dark"
        }
    }
    var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }
}

@main
struct GearLinkApp: App {
    @AppStorage("appAppearance") private var appearance: AppAppearance = .system

    var body: some Scene {
        WindowGroup {
            ContentView()
                .preferredColorScheme(appearance.colorScheme)
        }
    }
}
