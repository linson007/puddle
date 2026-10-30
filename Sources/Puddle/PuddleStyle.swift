import SwiftUI

/// The product site's warm paper and forest palette, adapted to native appearances.
enum PuddleStyle {
    // Retain the shared accent name for the existing workspaces.
    static let teal = adaptive(0x345B42, dark: 0xA9C99C)
    static let background = adaptive(0xF6F7F2, dark: 0x1B211D)
    static let panel = adaptive(0xFFFFFC, dark: 0x242C26)
    static let sidebar = adaptive(0xF0F3EB, dark: 0x1E261F)
    static let inset = adaptive(0xE9EEDF, dark: 0x303D2F)
    static let line = adaptive(0xDCE2D5, dark: 0x435043)
    static let ink = adaptive(0x24352C, dark: 0xEDF1E8)
    static let muted = adaptive(0x657068, dark: 0xAEB9AC)
    static let button = adaptive(0x345B42, dark: 0xBDD6AD)
    static let buttonText = adaptive(0xFFFFFF, dark: 0x20311F)

    private static func adaptive(_ light: UInt32, dark: UInt32) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let value = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
            return NSColor(srgbRed: CGFloat((value >> 16) & 0xff) / 255,
                           green: CGFloat((value >> 8) & 0xff) / 255,
                           blue: CGFloat(value & 0xff) / 255, alpha: 1)
        })
    }
}

struct PuddlePrimaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .semibold))
            .padding(.horizontal, 14).padding(.vertical, 9)
            .foregroundStyle(isEnabled ? PuddleStyle.buttonText : PuddleStyle.muted)
            .background(isEnabled ? PuddleStyle.button : PuddleStyle.inset, in: RoundedRectangle(cornerRadius: 8))
            .opacity(configuration.isPressed ? 0.8 : 1)
            .contentShape(RoundedRectangle(cornerRadius: 8))
    }
}

struct PuddleSecondaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .medium))
            .padding(.horizontal, 12).padding(.vertical, 9)
            .foregroundStyle(isEnabled ? PuddleStyle.teal : PuddleStyle.muted)
            .background(configuration.isPressed ? PuddleStyle.inset : PuddleStyle.panel, in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(PuddleStyle.line))
            .opacity(isEnabled ? 1 : 0.65)
            .contentShape(RoundedRectangle(cornerRadius: 8))
    }
}

struct PuddleTextButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label.foregroundStyle(isEnabled ? PuddleStyle.teal : PuddleStyle.muted)
            .opacity(configuration.isPressed || !isEnabled ? 0.6 : 1)
            .contentShape(Rectangle())
    }
}

/// Wrap action controls at their natural widths instead of forcing a tall column.
struct PuddleActionFlow: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        arrangement(width: proposal.width ?? .infinity, subviews: subviews).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let result = arrangement(width: bounds.width, subviews: subviews)
        for index in subviews.indices {
            let point = result.origins[index]
            subviews[index].place(at: CGPoint(x: bounds.minX + point.x, y: bounds.minY + point.y),
                                 proposal: ProposedViewSize(result.sizes[index]))
        }
    }

    private func arrangement(width: CGFloat, subviews: Subviews) -> (size: CGSize, origins: [CGPoint], sizes: [CGSize]) {
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0, usedWidth: CGFloat = 0
        var origins: [CGPoint] = [], sizes: [CGSize] = []
        for subview in subviews {
            let natural = subview.sizeThatFits(.unspecified)
            let size = subview.sizeThatFits(ProposedViewSize(width: min(natural.width, max(0, width)), height: nil))
            if x > 0 && x + size.width > width {
                x = 0; y += rowHeight + spacing; rowHeight = 0
            }
            origins.append(CGPoint(x: x, y: y)); sizes.append(size)
            usedWidth = max(usedWidth, x + size.width)
            x += size.width + spacing; rowHeight = max(rowHeight, size.height)
        }
        return (CGSize(width: usedWidth, height: y + rowHeight), origins, sizes)
    }
}

extension View {
    func puddleCard(padding: CGFloat = 20) -> some View {
        self.padding(padding).frame(maxWidth: .infinity, alignment: .leading)
            .background(PuddleStyle.panel, in: RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(PuddleStyle.line.opacity(0.8)))
    }
}
