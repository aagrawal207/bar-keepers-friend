import BarKeepersFriendCore
import SwiftUI

// Rendering and drag feedback use cached values; a drop only stages a choice in the Settings model.
struct SettingsPlacementPreview: View {
    let shown: [FloatingBarItem]
    let hidden: [FloatingBarItem]
    var alwaysHidden: [FloatingBarItem] = []
    let unknown: [FloatingBarItem]
    let style: FloatingBarStyle
    var useFloatingBar = true
    var hasPendingChanges = false
    var placementInProgress = false
    var anchorSymbol: AppIconChoice.MenuBarSymbol = .lines
    var metrics: FloatingBarLayout.Metrics = .default
    var dragModel: SettingsModel?

    private var barMetrics: FloatingBarLayout.Metrics {
        var compact = metrics
        compact.padding = min(compact.padding, 5)
        return compact
    }

    private var phase: String {
        if placementInProgress { return "Applying" }
        return hasPendingChanges ? "After Apply" : "Last Observed"
    }

    private var pendingNotice: String {
        guard hasPendingChanges else { return "" }
        return dragModel?.hasPendingPlacementChanges == false
            ? " Order changes are staged until Apply." : " After Apply includes saved placement requests."
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                SettingsSearchSectionHeading(target: .placementPreview, id: "settings-preview-heading")
                    .font(.subheadline.weight(.medium))
                Spacer()
                Text(phase)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("settings-preview-phase")
            }

            VStack(spacing: 6) {
                Bar(items: shown, placement: .shown, metrics: barMetrics, anchorSymbol: anchorSymbol, model: dragModel)
                Bar(items: hidden, placement: .hidden, metrics: barMetrics, anchorSymbol: anchorSymbol, model: dragModel)
                Bar(items: alwaysHidden, placement: .alwaysHidden, metrics: barMetrics, anchorSymbol: anchorSymbol, model: dragModel)
            }

            if !unknown.isEmpty {
                HStack(spacing: 8) {
                    Label("Placement unknown (\(unknown.count))", systemImage: "questionmark.circle")
                        .font(.caption)
                        .fixedSize()
                    ScrollView(.horizontal) {
                        HStack(spacing: 12) {
                            ForEach(unknown) { item in
                                Text(item.displayName)
                                    .font(.caption)
                                    .lineLimit(1)
                                    .accessibilityLabel(item.displayName)
                                    .accessibilityValue("Placement unknown")
                                    .accessibilityIdentifier("settings-preview-item-\(item.id)")
                                    .help(item.displayName)
                                    .overlay {
                                        if let dragModel {
                                            SettingsPlacementDragSource(model: dragModel, item: item, placement: nil, iconSize: metrics.iconSize)
                                                .accessibilityHidden(true)
                                        }
                                    }
                            }
                        }
                    }
                    .frame(height: 20)
                }
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("settings-preview-unknown")
                .help("These items have no observed placement and no placement selected for this preview.")
            }

            Text("Using cached glyphs or app icons; spacing may differ. Always Hidden opens with Option-click."
                 + pendingNotice
                 + (style == .vertical ? " Hidden items open in a vertical list." : ""))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("settings-preview-caption")

            if !useFloatingBar {
                Text("Hidden bar is disabled. Apply arranges these items in the native menu bar.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("settings-preview-disabled")
            }
        }
        .frame(maxWidth: 608, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
    }

    private struct Bar: View {
        let items: [FloatingBarItem]
        let placement: ItemPlacement
        let metrics: FloatingBarLayout.Metrics
        let anchorSymbol: AppIconChoice.MenuBarSymbol
        let model: SettingsModel?
        @State private var isTargeted = false

        private var section: String {
            switch placement {
            case .shown: "Shown"
            case .hidden: "Hidden"
            case .alwaysHidden: "Always Hidden"
            }
        }

        private var identifier: String {
            switch placement {
            case .shown: "settings-preview-menu-bar"
            case .hidden: "settings-preview-hidden"
            case .alwaysHidden: "settings-preview-always-hidden"
            }
        }

        private var target: SettingsSearchTarget {
            switch placement {
            case .shown: .menuBarPlacement
            case .hidden: .hiddenPlacement
            case .alwaysHidden: .alwaysHiddenPlacement
            }
        }

        var body: some View {
            HStack(spacing: 10) {
                SettingsSearchSectionHeading(target: target, id: "\(identifier)-heading")
                    .font(.caption.weight(.medium))
                    .frame(width: 90, alignment: .leading)
                Group {
                    if let model {
                        SettingsPlacementDropArea(model: model, placement: placement,
                                                  height: metrics.itemExtent + metrics.padding * 2,
                                                  isTargeted: $isTargeted) { content }
                    } else {
                        content
                    }
                }
                .frame(maxWidth: .infinity)
                .frame(height: metrics.itemExtent + metrics.padding * 2)
                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
                .overlay {
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(Color.accentColor, lineWidth: 2)
                        .opacity(isTargeted && model?.isDraggingPlacementItem == true ? 1 : 0)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier(identifier)
        }

        private var content: some View {
            HStack(spacing: 0) {
                if placement == .shown {
                    Label("BKF", systemImage: anchorSymbol.systemName)
                        .font(.caption)
                        .padding(.leading, metrics.padding)
                        .padding(.trailing, 4)
                        .accessibilityLabel("Bar Keeper's Friend anchor reference")
                        .help("Shown items sit to the right of the BKF anchor.")
                        .fixedSize()
                    Divider().frame(height: metrics.itemExtent)
                }
                Items(items: items, style: .horizontal, section: section, metrics: metrics,
                      dragModel: model, placement: placement)
            }
        }
    }

    struct Items: View {
        let items: [FloatingBarItem]
        let style: FloatingBarStyle
        let section: String
        var metrics: FloatingBarLayout.Metrics = .default
        var dragModel: SettingsModel?
        var placement: ItemPlacement?

        var body: some View {
            Group {
                if items.isEmpty {
                    Text(dragModel.map { _ in "Drop icons here" } ?? "No items in this preview")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .frame(maxWidth: .infinity, minHeight: metrics.itemExtent, alignment: .leading)
                        .padding(metrics.padding)
                } else {
                    ScrollView(style == .horizontal ? .horizontal : .vertical) {
                        if style == .horizontal {
                            HStack(spacing: 0) {
                                ForEach(items) { item in
                                    Item(item: item, style: style, section: section, metrics: metrics, dragModel: dragModel, placement: placement)
                                }
                            }
                            .padding(metrics.padding)
                        } else {
                            VStack(alignment: .leading, spacing: 0) {
                                ForEach(items) { item in
                                    Item(item: item, style: style, section: section, metrics: metrics, dragModel: dragModel, placement: placement)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(metrics.padding)
                        }
                    }
                    .scrollBounceBehavior(.basedOnSize)
                    .defaultScrollAnchor(.topLeading)
                    .frame(height: metrics.itemExtent * CGFloat(style == .horizontal ? 1 : min(items.count, 2))
                           + metrics.padding * 2)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .clipped()
            .accessibilityElement(children: .contain)
            .accessibilityLabel("\(section) preview")
        }
    }

    struct Item: View {
        let item: FloatingBarItem
        let style: FloatingBarStyle
        let section: String
        var metrics: FloatingBarLayout.Metrics = .default
        var dragModel: SettingsModel?
        var placement: ItemPlacement?
        @State private var isHovered = false

        private var help: String {
            guard let dragModel else { return "\(item.displayName) - \(section). Preview only." }
            if let group = dragModel.group(containing: item) {
                return "\(item.displayName) is in \(group.name). Manage its placement in Advanced → Groups."
            }
            let visibility = dragModel.isShownInBar(item) ? "" : " Not drawn in the floating bar."
            return "\(item.displayName) - \(section). Drag between icons or to another bar, then Apply Changes.\(visibility)"
        }

        var body: some View {
            HStack(spacing: 8) {
                Image(nsImage: item.image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: metrics.iconSize, height: metrics.iconSize)
                if style == .vertical {
                    Text(item.displayName)
                        .font(.callout)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 0)
                }
            }
            .padding(.horizontal, style == .vertical ? 8 : 0)
            .frame(width: metrics.itemExtent + (style == .vertical ? metrics.rowLabelWidth : 0),
                   height: metrics.itemExtent)
            .foregroundStyle(.primary)
            .background {
                RoundedRectangle(cornerRadius: 5)
                    .fill(Color.accentColor.opacity(isHovered && dragModel?.canDragPlacement(of: item, from: placement) == true ? 0.12 : 0))
                    .allowsHitTesting(false)
            }
            .opacity(dragModel.map { $0.isDraggingPlacement(item) ? 0.3 : ($0.isShownInBar(item) ? 1 : 0.5) } ?? 1)
            .onHover { isHovered = $0 }
            .overlay {
                if let dragModel {
                    SettingsPlacementDragSource(model: dragModel, item: item, placement: placement, iconSize: metrics.iconSize)
                        .accessibilityHidden(true)
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityAddTraits(.isStaticText)
            .accessibilityLabel(item.displayName)
            .accessibilityValue(section)
            .accessibilityHint(dragModel == nil ? "" : "Drag to arrange, then Apply Changes. Items from the same app move together.")
            .accessibilityAction(named: "Move earlier") { dragModel?.moveInBar(item, .earlier) }
            .accessibilityAction(named: "Move later") { dragModel?.moveInBar(item, .later) }
            .accessibilityIdentifier("settings-preview-item-\(item.id)")
            .help(help)
        }
    }
}
