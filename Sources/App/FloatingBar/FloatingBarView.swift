import BarKeepersFriendCore
import SwiftUI

/// The SwiftUI content of the floating bar. Renders the mirrored hidden icons either as a
/// horizontal strip or a vertical list, in a rounded translucent panel that reads well over
/// the transparent Tahoe (Liquid Glass) menu bar.
struct FloatingBarView: View {
    let items: [FloatingBarItem]
    let style: FloatingBarStyle
    /// True during the launch warm-up before the first capture completes, so an empty list
    /// reads as "preparing" (spinner) rather than the misleading "no hidden items" copy.
    var isPreparing: Bool = false
    /// Invoked when the user clicks a mirrored icon. Wired to real-item activation in the
    /// click-routing step; harmless no-op until then.
    var onActivate: (FloatingBarItem) -> Void

    private let iconSide: CGFloat = 18

    var body: some View {
        Group {
            if items.isEmpty {
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
        Text("No hidden items.\nDrag menu bar icons to the left of the anchor to hide them.")
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
        Group {
            switch style {
            case .horizontal:
                HStack(spacing: 6) {
                    ForEach(items) { item in
                        iconButton(item)
                    }
                }
                .padding(8)
            case .vertical:
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(items) { item in
                        Button {
                            onActivate(item)
                        } label: {
                            HStack(spacing: 8) {
                                Image(nsImage: item.image)
                                    .resizable()
                                    .aspectRatio(contentMode: .fit)
                                    .frame(width: iconSide, height: iconSide)
                                Text(item.displayName)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                Spacer(minLength: 0)
                            }
                            .padding(.horizontal, 8)
                            .frame(height: 28)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .disabled(item.isDisabled)
                        .opacity(item.isDisabled ? 0.4 : 1)
                        .help(item.isDisabled ? "This item can't be activated" : item.displayName)
                    }
                }
                .padding(8)
                .frame(width: 200)
            }
        }
    }

    private func iconButton(_ item: FloatingBarItem) -> some View {
        Button {
            onActivate(item)
        } label: {
            Image(nsImage: item.image)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: iconSide, height: iconSide)
                .frame(width: 26, height: 26)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(item.isDisabled)
        .opacity(item.isDisabled ? 0.4 : 1)
        .help(item.isDisabled ? "This item can't be activated" : item.displayName)
    }
}
