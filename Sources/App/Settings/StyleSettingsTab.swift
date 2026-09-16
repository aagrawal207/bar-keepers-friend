import AppKit
import BarKeepersFriendCore
import SwiftUI

/// Discrete controls write `model.preferences` once per change; color wells and the opacity slider
/// stream while dragged, so they coalesce through `MenuBarStyleEditor`. Nothing here touches placement.
struct StyleSettingsTab: View {
    @Bindable var model: SettingsModel
    @State private var editor: MenuBarStyleEditor

    /// Tests inject an editor with a fake timer; the app lets the tab own one per view identity.
    init(model: SettingsModel, editor: MenuBarStyleEditor? = nil) {
        self.model = model
        _editor = State(initialValue: editor ?? MenuBarStyleEditor(model: model))
    }

    private var displayed: MenuBarStyle { editor.displayed }

    /// One write per change; the getter includes any streaming edit still waiting to land.
    private var committed: Binding<MenuBarStyle> {
        Binding(get: { editor.displayed }, set: { editor.commit($0) })
    }

    /// Debounced writes for controls that emit continuously while dragged.
    private var streaming: Binding<MenuBarStyle> {
        Binding(get: { editor.displayed }, set: { editor.stage($0) })
    }

    private func colorBinding(_ keyPath: WritableKeyPath<MenuBarStyle, RGBA>) -> Binding<Color> {
        Binding(
            get: { editor.displayed[keyPath: keyPath].color },
            set: { newColor in
                var style = editor.displayed
                style[keyPath: keyPath] = RGBA(newColor)
                editor.stage(style)
            }
        )
    }

    private var gradientEndColor: Binding<Color> {
        Binding(
            get: { (editor.displayed.gradientEnd ?? MenuBarStyle.defaultGradientEnd).color },
            set: { newColor in
                var style = editor.displayed
                style.gradientEnd = RGBA(newColor)
                editor.stage(style)
            }
        )
    }

    private var gradientEnabled: Binding<Bool> {
        Binding(
            get: { editor.displayed.hasGradient },
            set: { enabled in
                var style = editor.displayed
                style.gradientEnd = enabled ? (style.gradientEnd ?? MenuBarStyle.defaultGradientEnd) : nil
                editor.commit(style)
            }
        )
    }

    var body: some View {
        Form {
            AppIconSettingsSection(model: model)

            Section {
                Toggle("Style the menu bar", isOn: committed.isEnabled)
                    .accessibilityIdentifier("settings-style-enabled")
                    .settingsSearchTarget(.menuBarStyle, including: displayed.isEnabled ? [] : SettingsSearchTarget.styleControls)

                if displayed.isEnabled {
                    // Related controls share rows to keep the style section compact.
                    LabeledContent("Tint") {
                        HStack(spacing: 12) {
                            ColorPicker("Tint color", selection: colorBinding(\.tint), supportsOpacity: false)
                                .labelsHidden()
                                .accessibilityLabel("Tint color")
                                .accessibilityIdentifier("settings-style-tint")
                                .settingsSearchTarget(.tint)
                            Toggle("Gradient", isOn: gradientEnabled)
                                .accessibilityIdentifier("settings-style-gradient-enabled")
                                .settingsSearchTarget(.gradient)
                            if displayed.hasGradient {
                                ColorPicker("Gradient end color", selection: gradientEndColor, supportsOpacity: false)
                                    .labelsHidden()
                                    .accessibilityLabel("Gradient end color")
                                    .accessibilityIdentifier("settings-style-gradient-end")
                            }
                        }
                    }
                    LabeledContent("Opacity") {
                        HStack(spacing: 8) {
                            Slider(value: streaming.opacity, in: MenuBarStyle.opacityRange)
                                .accessibilityLabel("Opacity")
                                .accessibilityIdentifier("settings-style-opacity")
                            Text(Self.percent(displayed.opacity))
                                .monospacedDigit()
                                .frame(width: 44, alignment: .trailing)
                                .accessibilityIdentifier("settings-style-opacity-value")
                        }
                    }
                    .accessibilityElement(children: .contain)
                    .accessibilityIdentifier("settings-style-opacity-row")
                    .settingsSearchTarget(.opacity)
                    Picker("Shape", selection: committed.shape) {
                        Text("Full").tag(MenuBarStyle.Shape.full)
                        Text("Rounded").tag(MenuBarStyle.Shape.rounded)
                        Text("Pill").tag(MenuBarStyle.Shape.pill)
                    }
                    .pickerStyle(.segmented)
                    .accessibilityIdentifier("settings-style-shape")
                    .settingsSearchTarget(.shape)
                    LabeledContent("Corner radius") {
                        Stepper(value: committed.cornerRadius, in: MenuBarStyle.cornerRadiusRange, step: 1) {
                            Text(Self.points(displayed.cornerRadius))
                                .monospacedDigit()
                                .frame(minWidth: 38, alignment: .trailing)
                        }
                        .fixedSize()
                        .accessibilityIdentifier("settings-style-corner-radius")
                    }
                    .disabled(!displayed.shape.usesCornerRadius)
                    .settingsSearchTarget(.cornerRadius)
                    LabeledContent("Border") {
                        HStack(spacing: 12) {
                            Stepper(value: committed.borderWidth, in: MenuBarStyle.borderWidthRange, step: 1) {
                                Text(displayed.hasBorder ? Self.points(displayed.borderWidth) : "None")
                                    .monospacedDigit()
                                    .frame(minWidth: 38, alignment: .trailing)
                            }
                            .fixedSize()
                            .accessibilityIdentifier("settings-style-border-width")
                            if displayed.hasBorder {
                                ColorPicker("Border color", selection: colorBinding(\.borderColor), supportsOpacity: true)
                                    .labelsHidden()
                                    .accessibilityLabel("Border color")
                                    .accessibilityIdentifier("settings-style-border-color")
                            }
                        }
                    }
                    .accessibilityElement(children: .contain)
                    .accessibilityIdentifier("settings-style-border-row")
                    .settingsSearchTarget(.border)
                    HStack {
                        Toggle("Shadow", isOn: committed.shadowEnabled)
                            .accessibilityIdentifier("settings-style-shadow")
                            .settingsSearchTarget(.shadow)
                        Spacer()
                        // Reset restores the default look but leaves styling on; the toggle above turns it off.
                        Button("Reset Style") { editor.commit(MenuBarStyle(isEnabled: true)) }
                            .disabled(displayed.isDefaultAppearance)
                            .accessibilityIdentifier("settings-style-reset")
                            .settingsSearchTarget(.resetStyle)
                    }
                }
                MenuBarStylePreview(style: displayed)
                    .settingsSearchTarget(.stylePreview)
            } header: {
                Text("Menu bar")
            } footer: {
                Text("Styling needs no permissions and does not change the menu bar's text or icons. If the style is hidden, turn off “Show menu bar background” in System Settings → Menu Bar. App artwork changes in Settings, About, and alerts; the Finder icon stays as shipped.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("settings-style-note")
            }
        }
        .formStyle(.grouped)
        .onDisappear { editor.flush() }
    }

    static func percent(_ value: Double) -> String {
        "\(Int((value * 100).rounded()))%"
    }

    static func points(_ value: Double) -> String {
        "\(Int(value.rounded())) pt"
    }
}

/// BKF's own artwork. Each choice writes preferences once; nothing here reads or moves menu bar items.
struct AppIconSettingsSection: View {
    @Bindable var model: SettingsModel

    private var choice: AppIconChoice { model.preferences.appIcon }

    /// Re-selecting the current value must not persist and re-apply an unchanged icon.
    private var menuBarSymbol: Binding<AppIconChoice.MenuBarSymbol> { Self.menuBarSymbolBinding(model) }

    /// The picker's binding, shared with tests because a pop-up's menu items are not reachable off screen.
    static func menuBarSymbolBinding(_ model: SettingsModel) -> Binding<AppIconChoice.MenuBarSymbol> {
        Binding(
            get: { model.preferences.appIcon.menuBarSymbol },
            set: { symbol in
                guard symbol != model.preferences.appIcon.menuBarSymbol else { return }
                model.preferences.appIcon.menuBarSymbol = symbol
            }
        )
    }

    private func select(theme: AppIconChoice.AppTheme) {
        guard theme != model.preferences.appIcon.appTheme else { return }
        model.preferences.appIcon.appTheme = theme
    }

    var body: some View {
        Section("Icons") {
            // One row: the pop-up is narrow and five 28pt swatches fit beside it, which keeps the
            // richest Style pane inside the window without scrolling.
            LabeledContent("Menu bar icon") {
                HStack(spacing: 12) {
                    Picker("Menu bar icon", selection: menuBarSymbol) {
                        ForEach(AppIconChoice.MenuBarSymbol.allCases) { symbol in
                            Label(symbol.displayName, systemImage: symbol.systemName)
                                .tag(symbol)
                        }
                    }
                    .labelsHidden()
                    .fixedSize()
                    .accessibilityLabel("Menu bar icon")
                    .accessibilityIdentifier("settings-icon-menu-bar")
                    Spacer(minLength: 8)
                    // The swatch group carries the accessible name; this caption is visual only.
                    Text("App icon")
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                    HStack(spacing: 8) {
                        ForEach(AppIconChoice.AppTheme.allCases) { theme in
                            AppThemeSwatch(theme: theme, isSelected: theme == choice.appTheme) {
                                select(theme: theme)
                            }
                        }
                    }
                    .help("The app icon changes in Settings, About, and alerts. The installed icon in Finder stays as shipped.")
                    .accessibilityElement(children: .contain)
                    .accessibilityLabel("App icon")
                    .accessibilityIdentifier("settings-icon-app-theme")
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("settings-icons-row")
            .settingsSearchTarget(.icons)
        }
    }
}

private struct AppThemeSwatch: View {
    let theme: AppIconChoice.AppTheme
    let isSelected: Bool
    let select: () -> Void

    var body: some View {
        Button(action: select) {
            Image(nsImage: AppIconRenderer.appImage(theme, size: 96))
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 28, height: 28)
                .overlay {
                    if isSelected {
                        RoundedRectangle(cornerRadius: 7)
                            .strokeBorder(Color.accentColor, lineWidth: 2)
                    }
                }
        }
        .buttonStyle(.plain)
        .help(theme.displayName)
        .accessibilityLabel("\(theme.displayName) app icon")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityIdentifier("settings-icon-app-theme-\(theme.rawValue)")
    }
}

/// Coalesces streaming style edits into one preferences write per quiet period, while discrete
/// edits write immediately. The pending edit is what the tab displays, so the preview stays live.
@MainActor
@Observable
final class MenuBarStyleEditor {
    typealias Scheduler = @MainActor (TimeInterval, @escaping @MainActor @Sendable () -> Void) -> @MainActor () -> Void

    /// Long enough to swallow a color-well drag, short enough that a release lands promptly.
    static let commitDelay: TimeInterval = 0.15

    private let model: SettingsModel
    private let schedule: Scheduler
    @ObservationIgnored private var cancelTimer: (@MainActor () -> Void)?
    /// The saved style when streaming began; a change elsewhere in the meantime wins over the edit.
    @ObservationIgnored private var base: MenuBarStyle?
    private(set) var pending: MenuBarStyle?

    init(model: SettingsModel, scheduler: Scheduler? = nil) {
        self.model = model
        self.schedule = scheduler ?? MenuBarStyleEditor.scheduleTimer
    }

    var saved: MenuBarStyle { model.preferences.menuBarStyle }
    var displayed: MenuBarStyle { pending ?? saved }

    /// Records a streaming edit and (re)arms the commit timer.
    func stage(_ style: MenuBarStyle) {
        let style = style.normalized()
        guard style != displayed else { return }
        if base == nil { base = saved }
        pending = style
        cancelTimer?()
        cancelTimer = schedule(Self.commitDelay) { [weak self] in self?.flush() }
    }

    /// Writes immediately, folding in any pending streaming edit the caller built on.
    func commit(_ style: MenuBarStyle) {
        cancelTimer?()
        cancelTimer = nil
        pending = nil
        base = nil
        let style = style.normalized()
        if style != saved { model.preferences.menuBarStyle = style }
    }

    /// Writes the pending edit now, unless the saved style moved underneath it.
    func flush() {
        cancelTimer?()
        cancelTimer = nil
        guard let pending else { return }
        let base = self.base
        self.pending = nil
        self.base = nil
        if let base, base != saved { return }
        if pending != saved { model.preferences.menuBarStyle = pending }
    }

    private static func scheduleTimer(
        delay: TimeInterval, fire: @escaping @MainActor @Sendable () -> Void
    ) -> @MainActor () -> Void {
        let timer = Timer(timeInterval: delay, repeats: false) { _ in
            MainActor.assumeIsolated { fire() }
        }
        RunLoop.main.add(timer, forMode: .common)
        return { timer.invalidate() }
    }
}

// MARK: - Color bridging

extension RGBA {
    /// sRGB components of a SwiftUI color, resolved without any environment.
    init(_ color: Color) {
        let resolved = color.resolve(in: EnvironmentValues())
        self.init(
            red: Double(resolved.red), green: Double(resolved.green),
            blue: Double(resolved.blue), alpha: Double(resolved.opacity)
        )
    }

    var color: Color {
        Color(.sRGB, red: red, green: green, blue: blue, opacity: alpha)
    }
}

// MARK: - Preview

/// A schematic of a notched 24pt menu bar over a stand-in wallpaper, painted by the same view as
/// the live overlay. It shows the style, not the real bar: item positions and text are invented.
struct MenuBarStylePreview: View {
    let style: MenuBarStyle

    static let menuBarHeight: CGFloat = 24
    static let desktopHeight: CGFloat = 36
    static let notchWidth: CGFloat = 120
    static let displayHeight: CGFloat = 400

    var body: some View {
        GeometryReader { proxy in
            content(width: max(proxy.size.width, 1))
        }
        .frame(height: Self.menuBarHeight + Self.desktopHeight)
        .accessibilityElement(children: .ignore)
        .accessibilityAddTraits(.isImage)
        .accessibilityLabel("Menu bar style preview")
        .accessibilityValue(Self.description(of: style))
        .accessibilityIdentifier("settings-style-preview")
    }

    static func notch(width: CGFloat) -> NotchGeometry {
        let sideWidth = max((width - notchWidth) / 2, 0)
        let top = displayHeight - menuBarHeight
        return NotchGeometry(
            displayFrame: CGRect(x: 0, y: 0, width: width, height: displayHeight),
            leftArea: CGRect(x: 0, y: top, width: sideWidth, height: menuBarHeight),
            rightArea: CGRect(x: width - sideWidth, y: top, width: sideWidth, height: menuBarHeight)
        )
    }

    static func layout(style: MenuBarStyle, width: CGFloat) -> MenuBarStyleGeometry.Layout? {
        MenuBarStyleGeometry.layout(
            displayFrame: CGRect(x: 0, y: 0, width: width, height: displayHeight),
            menuBarHeight: menuBarHeight, notch: notch(width: width), style: style
        )
    }

    static func description(of style: MenuBarStyle) -> String {
        let style = style.normalized()
        guard style.isEnabled else { return "Styling off" }
        var parts = [style.shape.rawValue.capitalized, "tint \(style.tint.hexString)"]
        if let end = style.gradientEnd { parts.append("gradient to \(end.hexString)") }
        parts.append("\(StyleSettingsTab.percent(style.opacity)) opacity")
        if style.hasBorder { parts.append("\(StyleSettingsTab.points(style.borderWidth)) border") }
        if style.shadowEnabled { parts.append("shadow") }
        return parts.joined(separator: ", ")
    }

    private func content(width: CGFloat) -> some View {
        let strip = CGSize(width: width, height: Self.menuBarHeight)
        return ZStack(alignment: .top) {
            LinearGradient(
                colors: [Color(red: 0.16, green: 0.42, blue: 0.85), Color(red: 0.45, green: 0.22, blue: 0.75)],
                startPoint: .topLeading, endPoint: .bottomTrailing
            )
            MenuBarStyleOverlayRepresentable(style: style, layout: Self.layout(style: style, width: width))
                .frame(width: strip.width, height: strip.height)
                .shadow(color: .black.opacity(style.isVisible && style.shadowEnabled ? 0.35 : 0), radius: 4, y: 2)
            fakeItems
                .frame(width: strip.width, height: strip.height)
            UnevenRoundedRectangle(bottomLeadingRadius: 8, bottomTrailingRadius: 8)
                .fill(.black)
                .frame(width: Self.notchWidth, height: strip.height)
        }
        .frame(width: width, height: Self.menuBarHeight + Self.desktopHeight)
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private var fakeItems: some View {
        HStack(spacing: 14) {
            Image(systemName: "apple.logo")
            Text("Finder").fontWeight(.bold)
            Text("File")
            Text("Edit")
            Text("View")
            Spacer()
            Image(systemName: "wifi")
            Image(systemName: "battery.75percent")
            Image(systemName: "magnifyingglass")
            Image(systemName: "switch.2")
            Text("Fri 9:41")
        }
        .font(.system(size: 13, weight: .semibold))
        .foregroundStyle(.white)
        .shadow(color: .black.opacity(0.4), radius: 1, y: 0.5)
        .padding(.horizontal, 14)
        .accessibilityHidden(true)
    }
}

/// Hosts the overlay's drawing view inside SwiftUI so the preview uses the production painter.
struct MenuBarStyleOverlayRepresentable: NSViewRepresentable {
    let style: MenuBarStyle
    let layout: MenuBarStyleGeometry.Layout?

    func makeNSView(context: Context) -> MenuBarStyleOverlayView {
        let view = MenuBarStyleOverlayView(frame: CGRect(origin: .zero, size: layout?.contentSize ?? .zero))
        view.configure(style: style, layout: layout)
        return view
    }

    func updateNSView(_ view: MenuBarStyleOverlayView, context: Context) {
        view.configure(style: style, layout: layout)
    }
}
