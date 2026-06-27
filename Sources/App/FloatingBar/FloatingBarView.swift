import BarKeepersFriendCore
import SwiftUI

/// The SwiftUI content of the floating bar. Renders the mirrored hidden icons either as a
/// horizontal strip or a vertical list, in a rounded translucent panel that reads well over
/// the transparent Tahoe (Liquid Glass) menu bar.
struct FloatingBarView: View {
    let items: [FloatingBarItem]
    let style: FloatingBarStyle
    /// Invoked when the user clicks a mirrored icon. Wired to real-item activation in the
    /// click-routing step; harmless no-op until then.
    var onActivate: (FloatingBarItem) -> Void

    private let iconSide: CGFloat = 18

    var body: some View {
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
                    }
                }
                .padding(8)
                .frame(width: 200)
            }
        }
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(.white.opacity(0.12), lineWidth: 1)
        )
        .fixedSize()
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
        .help(item.displayName)
    }
}
