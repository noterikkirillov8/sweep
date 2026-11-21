import SwiftUI

extension Color { static let teal = Color(red: 0x2B / 255, green: 0xB5 / 255, blue: 0xA0 / 255) }

extension View {
    /// Teal accent with dark text on it (white on #2BB5A0 is too faint).
    func sweepAccent() -> some View { kitAccent(.teal, onAccent: Color.black.opacity(0.85)) }
}

/// Brighter teal for selected bytes inside the strip (dark mode), deeper teal in light mode.
private struct Lit {
    static func color(_ dark: Bool) -> Color { dark ? Color(hex: 0x5CEBD4) : Color(hex: 0x0E8F7C) }
}

/// Segment widths for `totals` inside `width`, 1 pt gaps, every non-empty category at least 4 pt.
func stripWidths(_ totals: [Int64], _ width: CGFloat) -> [CGFloat] {
    let live = totals.filter { $0 > 0 }.count
    guard live > 0 else { return totals.map { _ in 0 } }
    let room = max(width - CGFloat(live - 1), 1), sum = CGFloat(totals.reduce(0, +)), minW: CGFloat = 4
    var w = totals.map { $0 > 0 ? max(minW, room * CGFloat($0) / sum) : 0 }
    let over = w.reduce(0, +) - room
    if over > 0 {                                   // shave the excess off the widest segments
        let big = w.reduce(0, +) - w.filter { $0 > 0 && $0 <= minW }.reduce(0, +)
        w = w.map { $0 > minW ? $0 - over * $0 / big : $0 }
    }
    return w
}

/// The signature: one 14 pt bar split by category. Doubles as a filter; selected bytes are lit inside each segment.
struct ReclaimStrip: View {
    let stats: [CatStat]
    var scanning: Bool
    var filter: Category?
    var onPick: (Category) -> Void
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { geo in
            let widths = stripWidths(stats.map(\.total), geo.size.width)
            ZStack(alignment: .leading) {
                Rectangle().fill(KitColor.well)
                Ticks().opacity(stats.contains { $0.total > 0 } ? 0 : 1)
                HStack(spacing: 0) {
                    ForEach(Array(stats.enumerated()), id: \.element.id) { i, s in
                        segment(s, widths[i]).padding(.trailing, widths[i] > 0 ? 1 : 0)
                    }
                }
                .animation(KitMotion.list, value: widths)
                if scanning {
                    if reduceMotion {
                        Rectangle().fill(KitColor.text).frame(width: 2).offset(x: min(widths.reduce(0, +) + CGFloat(widths.filter { $0 > 0 }.count), geo.size.width - 2))
                            .animation(KitMotion.list, value: widths)
                    } else {
                        TimelineView(.animation) { ctx in
                            let t = ctx.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1.8) / 1.8
                            Rectangle().fill(KitColor.text).frame(width: 2)
                                .offset(x: (geo.size.width - 2) * CGFloat(t))
                        }
                    }
                }
            }
        }
        .frame(height: 14)
        .clipShape(RoundedRectangle(cornerRadius: 3))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Reclaimable space by category")
    }

    private func segment(_ s: CatStat, _ w: CGFloat) -> some View {
        let frac = s.total > 0 ? min(1, CGFloat(s.picked) / CGFloat(s.total)) : 0
        let dim = filter != nil && filter != s.cat
        return ZStack(alignment: .leading) {
            Rectangle().fill(Color.teal.opacity(s.cat.shade))
            Rectangle().fill(Lit.color(scheme == .dark)).frame(width: w * frac)
        }
        .frame(width: w)
        .opacity(dim ? 0.35 : 1)
        .animation(KitMotion.soft, value: dim)
        .contentShape(Rectangle())
        .onTapGesture { onPick(s.cat) }
        .animation(KitMotion.list, value: frac)
    }
}

private struct Ticks: View {
    var body: some View {
        Canvas { ctx, size in
            var x: CGFloat = 12
            var i = 1
            while x < size.width {
                let h: CGFloat = i % 5 == 0 ? 8 : 4
                ctx.fill(Path(CGRect(x: x, y: (size.height - h) / 2, width: 1, height: h)), with: .color(KitColor.line))
                x += 12; i += 1
            }
        }
    }
}

/// One legend key under the strip: swatch, name, size. Pressing it filters the list.
struct CategoryKey: View {
    let stat: CatStat
    var active: Bool
    var dimmed: Bool
    var action: () -> Void
    @State private var hover = false
    @Environment(\.kitAccent) private var accent

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    RoundedRectangle(cornerRadius: 2).fill(Color.teal.opacity(stat.cat.shade)).frame(width: 8, height: 8)
                    Text(stat.cat.name).font(KitFont.key).foregroundStyle(active || hover ? KitColor.text : KitColor.text2).lineLimit(1)
                }
                Text(Fmt.bytes(stat.total)).font(.system(size: 12).monospacedDigit()).foregroundStyle(stat.total == 0 ? KitColor.text2 : KitColor.text)
                    .kitRollingNumber(stat.total).lineLimit(1)
            }
            .padding(.horizontal, 12)
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: KitSpace.controlRadius).fill(active ? KitColor.raised : (hover ? KitColor.well : .clear)))
            .overlay(alignment: .bottom) { if active { Rectangle().fill(accent).frame(height: 2).padding(.horizontal, 1) } }
            .clipShape(RoundedRectangle(cornerRadius: KitSpace.controlRadius))
            .contentShape(Rectangle())
            .opacity(dimmed ? 0.45 : 1)
        }
        .buttonStyle(.plain)
        .disabled(stat.total == 0 && !active)
        .onHover { hover = $0 }
        .accessibilityLabel("\(stat.cat.name), \(Fmt.bytes(stat.total))")
        .accessibilityAddTraits(active ? .isSelected : [])
    }
}
