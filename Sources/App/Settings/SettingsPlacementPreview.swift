import BarKeepersFriendCore
import SwiftUI

// These schematics accept only cached values, never a controller or an activation action.
struct SettingsPlacementPreview: View {
    let shown: [FloatingBarItem]
    let hidden: [FloatingBarItem]
    let unknown: [FloatingBarItem]
    let style: FloatingBarStyle
    var useFloatingBar = true
    var hasPendingChanges = false
    var placementInProgress = false
    var metrics: FloatingBarLayout.Metrics = .default

    private var phase: String {
        if placementInProgress { return "Applying" }
        return hasPendingChanges ? "After Apply" : "Last Observed"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Placement Preview")
                    .font(.subheadline.weight(.medium))
                Spacer()
                Text(phase)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("settings-preview-phase")
            }

            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Menu Bar")
                        .font(.caption.weight(.medium))
                        .accessibilityAddTraits(.isHeader)
                    HStack(spacing: 0) {
                        Label("BKF", systemImage: "line.3.horizontal.decrease.circle")
                            .font(.caption)
                            .padding(.leading, metrics.padding)
                            .padding(.trailing, 4)
                            .accessibilityLabel("Bar Keeper's Friend anchor reference")
                            .help("Shown items sit to the right of the BKF anchor.")
                            .fixedSize()
                        Divider()
                            .frame(height: metrics.itemExtent)
                        Items(items: shown, style: .horizontal, section: "Shown", metrics: metrics)
                    }
                    .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
                    .accessibilityElement(children: .contain)
                    .accessibilityIdentifier("settings-preview-menu-bar")
                }
                .frame(maxWidth: .infinity, alignment: .topLeading)

                VStack(alignment: .leading, spacing: 4) {
                    Text(style == .horizontal ? "Hidden Bar" : "Hidden List")
                        .font(.caption.weight(.medium))
                        .accessibilityAddTraits(.isHeader)
                    Items(items: hidden, style: style, section: "Hidden", metrics: metrics)
                        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
                }
                .frame(maxWidth: .infinity, alignment: .topLeading)
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("settings-preview-hidden")
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
                            }
                        }
                    }
                    .frame(height: 20)
                }
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("settings-preview-unknown")
                .help("These items have no observed placement and no placement selected for this preview.")
            }

            Text("Manageable items only, using cached glyphs or app icons. Not a live menu bar; spacing and order may differ."
                 + (hasPendingChanges ? " After Apply includes saved placement requests." : ""))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("settings-preview-caption")

            if !useFloatingBar {
                Text("Hidden bar is disabled. The hidden section above is a schematic only.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("settings-preview-disabled")
            }
        }
        .frame(maxWidth: 608, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
    }

    struct Items: View {
        let items: [FloatingBarItem]
        let style: FloatingBarStyle
        let section: String
        var metrics: FloatingBarLayout.Metrics = .default

        var body: some View {
            Group {
                if items.isEmpty {
                    Text("No items in this preview")
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
                                    Item(item: item, style: style, section: section, metrics: metrics)
                                }
                            }
                            .padding(metrics.padding)
                        } else {
                            VStack(alignment: .leading, spacing: 0) {
                                ForEach(items) { item in
                                    Item(item: item, style: style, section: section, metrics: metrics)
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
            .accessibilityElement(children: .ignore)
            .accessibilityAddTraits(.isStaticText)
            .accessibilityLabel(item.displayName)
            .accessibilityValue(section)
            .accessibilityIdentifier("settings-preview-item-\(item.id)")
            .help("\(item.displayName) - \(section). Preview only.")
        }
    }
}
