import BarKeepersFriendCore
import SwiftUI

/// The SwiftUI content of the floating bar. Renders the mirrored hidden icons either as a
/// horizontal strip or a vertical list, in a rounded translucent panel that reads well over
/// the transparent Tahoe (Liquid Glass) menu bar.
struct FloatingBarView: View {
    let items: [FloatingBarItem]
    /// The always-hidden tier, appended under a caption; empty for a plain (non-Option) open.
    var alwaysHiddenItems: [FloatingBarItem] = []
    let style: FloatingBarStyle
    /// True during the launch warm-up before the first capture completes, so an empty list
    /// reads as "preparing" (spinner) rather than the misleading "no hidden items" copy.
    var isPreparing: Bool = false
    /// Max items along the panel's primary axis before wrapping: a horizontal strip wraps to a new
    /// ROW after this many icons, a vertical list wraps to a new COLUMN after this many rows. Keeps
    /// a large hidden set from growing the panel off-screen. Defaults high so a small set is a
    /// single line; the controller passes the screen-derived value so it matches the panel frame.
    var itemsPerLine: Int = .max
    // Cell bounds and padding must match the Core layout used to size the panel.
    var metrics: FloatingBarLayout.Metrics = .default
    /// Invoked when the user clicks a mirrored icon. Wired to real-item activation in the
    /// click-routing step; harmless no-op until then.
    var onActivate: (FloatingBarItem) -> Void

    /// Accessibility label and caption text for the appended tier.
    static let alwaysHiddenCaption = "Always hidden"

    /// Items split into lines of at most `itemsPerLine` (a row for horizontal, a column for
    /// vertical), preserving order. The grid is filled line-by-line so wrapping matches
    /// `FloatingBarLayout`'s grid (which the panel frame is sized from).
    private func lines(of items: [FloatingBarItem]) -> [[FloatingBarItem]] {
        let per = max(1, itemsPerLine)
        guard per < items.count else { return items.isEmpty ? [] : [items] }
        return stride(from: 0, to: items.count, by: per).map {
            Array(items[$0 ..< min($0 + per, items.count)])
        }
    }

    var body: some View {
        Group {
            if items.isEmpty && alwaysHiddenItems.isEmpty {
                if isPreparing { preparingState } else { emptyState }
            } else {
                content
            }
        }
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(.white.opacity(0.12), lineWidth: 1)
        )
        .fixedSize()
    }

    private var emptyState: some View {
        Text("No hidden items.\nOpen Settings → Items and switch items to “Hidden” to keep them here.")
            .font(.callout)
            .multilineTextAlignment(.center)
            .foregroundStyle(.secondary)
            .padding(12)
            .frame(width: 240)
    }

    /// Shown on the very first open while the launch capture is still warming up, so a click
    /// during that window gets immediate feedback instead of an empty/misleading panel. The
    /// controller re-lays-out the panel as soon as the capture lands, replacing this.
    private var preparingState: some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text("Preparing…")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 14)
        .frame(height: 36)
    }

    @ViewBuilder
    private var content: some View {
        VStack(alignment: .leading, spacing: 0) {
            if !items.isEmpty {
                grid(items)
            }
            if !alwaysHiddenItems.isEmpty {
                alwaysHiddenHeader
                grid(alwaysHiddenItems)
            }
        }
        .padding(metrics.padding)
    }

    /// One tier laid into the style's grid: rows for a strip, columns for a list.
    @ViewBuilder
    private func grid(_ items: [FloatingBarItem]) -> some View {
        switch style {
        case .horizontal:
            // Each `lines` entry is a ROW; stack the rows vertically so a long strip wraps
            // instead of running off the screen edge.
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(lines(of: items).enumerated()), id: \.offset) { _, row in
                    HStack(spacing: 0) {
                        ForEach(row) { item in
                            iconButton(item)
                        }
                    }
                }
            }
        case .vertical:
            // Each `lines` entry is a COLUMN; stack the columns horizontally so a tall list
            // wraps into additional columns instead of running off the bottom.
            HStack(alignment: .top, spacing: 0) {
                ForEach(Array(lines(of: items).enumerated()), id: \.offset) { _, column in
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(column) { item in
                            verticalRow(item)
                        }
                    }
                    .frame(width: metrics.itemExtent + metrics.rowLabelWidth)
                }
            }
        }
    }

    /// Subtle separator so the appended tier reads as a distinct group, not more hidden items.
    private var alwaysHiddenHeader: some View {
        VStack(alignment: .leading, spacing: 4) {
            Divider()
            Text(Self.alwaysHiddenCaption)
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 6)
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Self.alwaysHiddenCaption)
        .accessibilityAddTraits(.isHeader)
        .accessibilityIdentifier("floating-bar-always-hidden-header")
    }

    private func verticalRow(_ item: FloatingBarItem) -> some View {
        Button {
            onActivate(item)
        } label: {
            HStack(spacing: 8) {
                Image(nsImage: item.image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: metrics.iconSize, height: metrics.iconSize)
                Text(item.displayName)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .frame(height: metrics.itemExtent)
            .contentShape(Rectangle())
        }
        .buttonStyle(FloatingBarItemButtonStyle())
        .disabled(item.isDisabled)
        .opacity(item.isDisabled ? 0.4 : 1)
        .help(item.isDisabled ? "This item can't be activated" : item.displayName)
    }

    private func iconButton(_ item: FloatingBarItem) -> some View {
        Button {
            onActivate(item)
        } label: {
            Image(nsImage: item.image)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: metrics.iconSize, height: metrics.iconSize)
                .frame(width: metrics.itemExtent, height: metrics.itemExtent)
                .contentShape(Rectangle())
        }
        .buttonStyle(FloatingBarItemButtonStyle())
        .disabled(item.isDisabled)
        .opacity(item.isDisabled ? 0.4 : 1)
        .help(item.isDisabled ? "This item can't be activated" : item.displayName)
    }
}

struct FloatingBarItemButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        Content(label: configuration.label, isPressed: configuration.isPressed)
    }

    struct Content<Label: View>: View {
        let label: Label
        var isPressed: Bool
        @State var isHovered = false
        @Environment(\.isEnabled) private var isEnabled

        var body: some View {
            label
                .background {
                    if isEnabled && (isHovered || isPressed) {
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(.primary.opacity(isPressed ? 0.22 : 0.12))
                            .padding(2)
                    }
                }
                .onHover { isHovered = $0 }
        }
    }
}
