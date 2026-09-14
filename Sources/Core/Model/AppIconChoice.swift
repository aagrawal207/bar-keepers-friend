import Foundation

/// The user's choice of BKF artwork. Both pickers are finite so a saved or imported value can
/// never point at artwork this build does not ship.
public struct AppIconChoice: Equatable, Hashable, Codable, Sendable {
    /// SF Symbol shown in the menu bar anchor. Raw values are on-disk keys; never rename them.
    public enum MenuBarSymbol: String, CaseIterable, Codable, Sendable, Identifiable {
        case lines
        case sparkle
        case sidebar
        case tray
        case circleDots

        public var id: Self { self }

        public var systemName: String {
            switch self {
            case .lines: "line.3.horizontal.decrease.circle"
            case .sparkle: "sparkle"
            case .sidebar: "sidebar.left"
            case .tray: "tray"
            case .circleDots: "ellipsis.circle"
            }
        }

        public var displayName: String {
            switch self {
            case .lines: "Filter lines"
            case .sparkle: "Sparkle"
            case .sidebar: "Sidebar"
            case .tray: "Tray"
            case .circleDots: "Dots"
            }
        }
    }

    /// Color theme for the app artwork shown in Settings, About, and alerts.
    public enum AppTheme: String, CaseIterable, Codable, Sendable, Identifiable {
        case ocean
        case sunset
        case forest
        case graphite
        case plum

        public var id: Self { self }

        public var displayName: String {
            switch self {
            case .ocean: "Ocean"
            case .sunset: "Sunset"
            case .forest: "Forest"
            case .graphite: "Graphite"
            case .plum: "Plum"
            }
        }

        /// Gradient stops for the icon background, top then bottom.
        public var gradient: (top: RGBA, bottom: RGBA) {
            switch self {
            case .ocean: (RGBA(red: 0.22, green: 0.86, blue: 0.80), RGBA(red: 0.07, green: 0.46, blue: 0.90))
            case .sunset: (RGBA(red: 0.99, green: 0.62, blue: 0.29), RGBA(red: 0.86, green: 0.19, blue: 0.42))
            case .forest: (RGBA(red: 0.47, green: 0.85, blue: 0.53), RGBA(red: 0.09, green: 0.47, blue: 0.33))
            case .graphite: (RGBA(red: 0.55, green: 0.57, blue: 0.62), RGBA(red: 0.17, green: 0.18, blue: 0.22))
            case .plum: (RGBA(red: 0.78, green: 0.53, blue: 0.95), RGBA(red: 0.40, green: 0.16, blue: 0.66))
            }
        }
    }

    public var menuBarSymbol: MenuBarSymbol
    public var appTheme: AppTheme

    public init(menuBarSymbol: MenuBarSymbol = .lines, appTheme: AppTheme = .ocean) {
        self.menuBarSymbol = menuBarSymbol
        self.appTheme = appTheme
    }

    /// The artwork this app has always shipped with.
    public static let `default` = AppIconChoice()

    // Explicit keys so renaming a Swift property never silently drops stored data.
    enum CodingKeys: String, CodingKey {
        case menuBarSymbol
        case appTheme
    }

    /// Unknown or malformed values fall back per field so one bad key cannot reset the other.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        menuBarSymbol = ((try? container.decodeIfPresent(MenuBarSymbol.self, forKey: .menuBarSymbol)) ?? nil) ?? .lines
        appTheme = ((try? container.decodeIfPresent(AppTheme.self, forKey: .appTheme)) ?? nil) ?? .ocean
    }
}
