import SwiftUI
import ServiceManagement

struct ContentView: View {
    @Bindable var model: SweepModel
    var qaChrome = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack(alignment: .bottom) {
            VStack(spacing: 0) {
                topBar
                hero
                ReclaimStrip(stats: model.stats, scanning: model.scanning, filter: model.filter, onPick: model.pick)
                    .padding(.horizontal, KitSpace.xl)
                legend
                KitDivider()
                if model.rows.isEmpty { empty } else { list }
                KitDivider()
                bottomBar
            }
            if model.confirmation != nil {
                ConfirmBar(model: model).transition(reduceMotion ? .opacity : .kitBar)
            }
        }
        .frame(minWidth: 760, minHeight: 560)
        .overlay(alignment: .top) { PowerHairline(on: model.powerOn && !reduceMotion) }
        .background(KitColor.window.ignoresSafeArea())
        .sweepAccent()
        .animation(model.confirmation != nil ? KitMotion.panelIn : KitMotion.panelOut, value: model.confirmation != nil)
        .modifier(WindowEntrance(shown: model.shown, reduce: reduceMotion))
    }

    // MARK: Top bar and hero

    var topBar: some View {
        HStack(spacing: KitSpace.m) {
            Text("Sweep").font(KitFont.title).foregroundStyle(KitColor.text)
            Spacer()
            Toggle("Include in use", isOn: $model.includeInUse).toggleStyle(.kitSwitch).fixedSize()
            KitIconButton(symbol: "gearshape", help: "Settings") { model.onSettings() }
        }
        .padding(.leading, 80).padding(.trailing, KitSpace.l)
        .frame(height: 44)
        .overlay(alignment: .leading) { if qaChrome { QALights() } }
    }

    var hero: some View {
        let p = Fmt.parts(model.reclaimable)
        return HStack(alignment: .bottom) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(p.0).font(KitFont.figure(34))
                    Text(p.1).font(KitFont.figure(16)).foregroundStyle(KitColor.text2)
                }
                .foregroundStyle(model.phase == .idle ? KitColor.text3 : KitColor.text)
                .kitRollingNumber(model.reclaimable)
                Text(heroCaption).font(KitFont.detail).foregroundStyle(KitColor.text2)
            }
            Spacer(minLength: KitSpace.l)
            Text(model.status).font(KitFont.detail).foregroundStyle(KitColor.text2).lineLimit(1).truncationMode(.middle)
                .frame(maxWidth: 300, alignment: .trailing).padding(.bottom, 6)
            if model.scanning {
                Button("Cancel") { model.cancel() }.buttonStyle(.kitSecondary).keyboardShortcut(.cancelAction)
            } else {
                Button(model.phase == .idle ? "Scan" : "Scan again") { model.scan() }.buttonStyle(.kitPrimary).keyboardShortcut("r")
            }
        }
        .padding(.horizontal, KitSpace.xl).padding(.top, KitSpace.s).padding(.bottom, KitSpace.m)
    }

    var heroCaption: String {
        switch model.phase {
        case .idle: "reclaimable"
        default: "reclaimable in \(model.reclaimableCount) \(model.reclaimableCount == 1 ? "folder" : "folders")"
        }
    }

    var legend: some View {
        HStack(spacing: 4) {
            ForEach(model.stats) { s in
                CategoryKey(stat: s, active: model.filter == s.cat, dimmed: s.total == 0 && model.filter != s.cat) { model.pick(s.cat) }
            }
        }
        .padding(.horizontal, KitSpace.m).padding(.vertical, KitSpace.m)
    }

    // MARK: List

    var list: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(Array(model.rows.enumerated()), id: \.element.id) { i, r in
                    switch r {
                    case .header(let name, let total, let count):
                        GroupHeader(name: name, total: total, count: count)
                            .transition(rowT)
                    case .item(let f):
                        ItemRow(item: f, on: model.selected.contains(f.id), selectable: model.selectable(f), maxSize: model.maxSize, model: model, stagger: model.stagger ? min(i, 14) : nil)
                            .equatable()
                            .transition(rowT)
                    }
                }
            }.padding(.bottom, KitSpace.s)
        }
    }

    var rowT: AnyTransition { reduceMotion ? .opacity : .kitRow }

    var empty: some View {
        VStack(spacing: KitSpace.m) {
            if model.scanning || model.phase == .idle {
                VStack(spacing: 0) { ForEach(0..<4, id: \.self) { SkeletonRow(seed: $0) } }.opacity(model.scanning ? 1 : 0.8)
                if model.phase == .idle {
                    Text("Nothing scanned yet").font(KitFont.title).foregroundStyle(KitColor.text)
                    Text("Press Scan to look through " + model.roots.map { Scanner.tilde($0, FileManager.default.homeDirectoryForCurrentUser) }.joined(separator: ", ") + ".")
                        .font(KitFont.body).foregroundStyle(KitColor.text2)
                }
            } else {
                Spacer()
                Text(model.filter == nil ? "Nothing to clean up" : "Nothing in \(model.filter!.name)").font(KitFont.title).foregroundStyle(KitColor.text)
                Text(model.filter == nil ? "No rebuildable folders were found." : "Pick another category or clear the filter.")
                    .font(KitFont.body).foregroundStyle(KitColor.text2)
                Spacer()
            }
            if model.scanning || model.phase == .idle { Spacer() }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: Bottom bar

    var bottomBar: some View {
        HStack(spacing: KitSpace.m) {
            VStack(alignment: .leading, spacing: 2) {
                if let m = model.message {
                    let parts = m.components(separatedBy: ". ")
                    HStack(spacing: KitSpace.m) {
                        KitLed(color: model.failures.isEmpty ? nil : KitColor.amber)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(parts[0] + (parts.count > 1 ? "." : "")).font(KitFont.bodyMedium).foregroundStyle(KitColor.text).lineLimit(1)
                            if !model.failures.isEmpty {
                                Text("Could not move: " + model.failures.joined(separator: "; ")).font(KitFont.detail).foregroundStyle(KitColor.red).lineLimit(1).truncationMode(.middle)
                            } else if parts.count > 1 {
                                Text(parts.dropFirst().joined(separator: ". ")).font(KitFont.detail).foregroundStyle(KitColor.text2).lineLimit(1)
                            }
                        }
                    }
                } else if model.selected.isEmpty {
                    Text("Nothing selected").font(KitFont.body).foregroundStyle(KitColor.text2)
                } else {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text("Selected").font(KitFont.detail).foregroundStyle(KitColor.text2)
                        let p = Fmt.parts(model.selectedBytes)
                        Text(p.0).font(KitFont.figure(20)).foregroundStyle(KitColor.text)
                        Text(p.1).font(KitFont.figure(12)).foregroundStyle(KitColor.text2)
                        Text("\(model.selected.count) \(model.selected.count == 1 ? "folder" : "folders")")
                            .font(KitFont.detail).foregroundStyle(KitColor.text2)
                    }
                    .kitRollingNumber(model.selectedBytes)
                }
            }
            Spacer()
            Button("Select older than 30 days") { model.selectOlder() }.buttonStyle(.kitQuiet).disabled(model.items.isEmpty || model.scanning)
            if model.canFreeSpace {
                Button("Free space now") { model.confirmation = .freeSpace }.buttonStyle(.kitSecondary)
            }
            if !model.canFreeSpace || !model.selected.isEmpty {
                Button(model.selectedCommands.isEmpty ? "Move to Trash" : "Clean up") { model.confirmation = .review }.buttonStyle(.kitPrimary).disabled(model.selected.isEmpty || model.scanning)
            }
        }
        .padding(.horizontal, KitSpace.xl).frame(height: 60)
        .animation(KitMotion.list, value: model.message)
        .animation(KitMotion.list, value: model.selected.isEmpty)
    }
}

// MARK: Rows

struct GroupHeader: View {
    let name: String
    let total: Int64?
    let count: Int
    var body: some View {
        HStack(spacing: 8) {
            if name == AgentDisk.group {
                Text("Safely reclaimable: \(total.map(Fmt.bytes) ?? "…")").font(KitFont.header).foregroundStyle(KitColor.text)
                Spacer()
            }
            Text(name).font(KitFont.header).foregroundStyle(KitColor.text)
            Text("\(count)").font(.system(size: 11).monospacedDigit()).foregroundStyle(KitColor.text2)
            if name != AgentDisk.group {
                Spacer()
                if let total { Text(Fmt.bytes(total)).font(.system(size: 11).monospacedDigit()).foregroundStyle(KitColor.text2).kitRollingNumber(total) }
            }
        }
        .padding(.horizontal, KitSpace.xl).padding(.top, KitSpace.m).frame(height: 36, alignment: .center)
    }
}

struct ItemRow: View, Equatable {
    let item: Found
    let on: Bool
    let selectable: Bool
    let maxSize: Int64
    let model: SweepModel
    var stagger: Int? = nil
    @State private var hover = false
    @State private var shown: Bool
    @Environment(\.kitAccent) private var accent

    init(item: Found, on: Bool, selectable: Bool, maxSize: Int64, model: SweepModel, stagger: Int?) {
        self.item = item; self.on = on; self.selectable = selectable; self.maxSize = maxSize; self.model = model; self.stagger = stagger
        _shown = State(initialValue: stagger == nil)
    }

    nonisolated static func == (a: ItemRow, b: ItemRow) -> Bool {
        a.item == b.item && a.on == b.on && a.selectable == b.selectable && a.maxSize == b.maxSize
    }

    var body: some View {
        HStack(spacing: KitSpace.m) {
            if let agent = item.agent, agent != .pushed {
                Image(systemName: "lock.fill").font(KitFont.detail).foregroundStyle(KitColor.text2).frame(width: 16).accessibilityLabel("Locked")
            } else {
                KitCheckbox(isOn: Binding(get: { on }, set: { _ in model.toggle(item) })).disabled(!selectable)
            }
            if let agent = item.agent {
                VStack(alignment: .leading, spacing: 3) {
                    path.lineLimit(1).truncationMode(.middle)
                    Text(agent.label).font(KitFont.detail).foregroundStyle(KitColor.text2)
                }.frame(maxWidth: .infinity, alignment: .leading)
                if agent != .history {
                    Text("Last active: \(Fmt.age(item.modified))").font(KitFont.detail).foregroundStyle(KitColor.text2)
                }
                sizeFigure
            } else {
            Text(item.kind).font(KitFont.detail).foregroundStyle(KitColor.text2).lineLimit(1)
                .frame(width: 104, alignment: .leading)
            path.lineLimit(1).truncationMode(.middle).frame(maxWidth: .infinity, alignment: .leading)
            if item.permanent { Text("Deletes permanently").font(KitFont.detail).foregroundStyle(KitColor.text2).fixedSize() }
            if item.inUse() { KitBadge(text: "in use", color: KitColor.amber) }
            sizeBar
            sizeFigure
            Text(item.permanent ? "" : Fmt.age(item.modified)).font(.system(size: 11).monospacedDigit()).foregroundStyle(KitColor.text2)
                .frame(width: 36, alignment: .trailing)
            }
        }
        .padding(.horizontal, KitSpace.xl).frame(height: item.agent == nil ? 32 : 46)
        .background(on ? accent.opacity(0.10) : (hover && selectable ? KitColor.well : .clear))
        .overlay(alignment: .leading) { if on { Rectangle().fill(accent).frame(width: 2) } }
        .opacity(shown ? (selectable || item.agent != nil ? 1 : 0.55) : 0)
        .offset(y: shown ? 0 : 8)
        .animation(KitMotion.soft, value: hover)
        .animation(KitMotion.list, value: on)
        .contentShape(Rectangle())
        .onTapGesture { model.toggle(item) }
        .onHover { hover = $0 }
        .onAppear { if let stagger, !shown { withAnimation(KitMotion.stagger(stagger)) { shown = true } } }
    }

    var path: Text {
        let d = item.display
        guard let slash = d.lastIndex(of: "/") else { return Text(d).font(KitFont.body).foregroundStyle(KitColor.text) }
        return Text(d[...slash]).font(KitFont.body).foregroundStyle(KitColor.text2)
            + Text(d[d.index(after: slash)...]).font(KitFont.body).foregroundStyle(KitColor.text)
    }

    var sizeBar: some View {
        let f = item.size.map { CGFloat($0) / CGFloat(max(maxSize, 1)) } ?? 0
        return ZStack(alignment: .leading) {
            Rectangle().fill(KitColor.well)
            Rectangle().fill(accent.opacity(on ? 1 : 0.55)).scaleEffect(x: max(f, f > 0 ? 0.02 : 0), anchor: .leading)
        }
        .frame(width: 80, height: 4).clipShape(RoundedRectangle(cornerRadius: 1))
    }

    var sizeFigure: some View {
        Group {
            if let s = item.size { Text(Fmt.bytes(s)).font(.system(size: 13, weight: .medium).monospacedDigit()).foregroundStyle(KitColor.text) }
            else { RoundedRectangle(cornerRadius: 2).fill(KitColor.well).frame(width: 44, height: 8) }
        }
        .frame(width: 76, alignment: .trailing)
    }
}

struct WindowEntrance: ViewModifier {
    var shown: Bool
    var reduce: Bool
    func body(content: Content) -> some View {
        if reduce { content.opacity(shown ? 1 : 0).animation(KitMotion.soft, value: shown) }
        else { content.kitPanelEntrance(shown, anchor: .center) }
    }
}

struct SkeletonRow: View {
    let seed: Int
    var body: some View {
        HStack(spacing: KitSpace.m) {
            RoundedRectangle(cornerRadius: 3.5).strokeBorder(KitColor.line, lineWidth: 1).frame(width: 16, height: 16)
            RoundedRectangle(cornerRadius: 2).fill(KitColor.line).frame(width: 90, height: 8)
            RoundedRectangle(cornerRadius: 2).fill(KitColor.line).frame(width: CGFloat(180 + (seed * 53) % 120), height: 8)
            Spacer()
            RoundedRectangle(cornerRadius: 1).fill(KitColor.line).frame(width: 96, height: 4)
            RoundedRectangle(cornerRadius: 2).fill(KitColor.line).frame(width: 44, height: 8)
        }
        .padding(.horizontal, KitSpace.xl).frame(height: 32)
    }
}

// MARK: Confirm bar (slides up over the bottom bar, no system sheet)

struct ConfirmBar: View {
    var model: SweepModel
    var body: some View {
        let commands = model.selectedCommands
        let folders = model.selectedFolderCount
        VStack(spacing: 0) {
            KitDivider()
            HStack(spacing: KitSpace.m) {
                KitLed(color: commands.isEmpty && model.confirmation != .freeSpace ? KitColor.amber : KitColor.red)
                VStack(alignment: .leading, spacing: 3) {
                    if model.confirmation == .freeSpace {
                        let count = model.lastTrashBatch.count
                        Text(count == 1 ? "Delete this 1 item for good?" : "Delete these \(count) items for good?")
                            .font(KitFont.bodyMedium).foregroundStyle(KitColor.text)
                        Text("Other things in the Trash stay.").font(KitFont.detail).foregroundStyle(KitColor.text2)
                    } else if commands.isEmpty {
                        Text("Move \(model.selected.count) \(model.selected.count == 1 ? "folder" : "folders"), \(Fmt.bytes(model.selectedBytes)), to the Trash?")
                            .font(KitFont.bodyMedium).foregroundStyle(KitColor.text)
                        Text("You can put them back from the Trash.").font(KitFont.detail).foregroundStyle(KitColor.text2)
                    } else {
                        if let warning = model.confirmation?.warning {
                            Text(model.selectedSimulators ? (model.selectedDockerKinds.isEmpty ? "Permanently delete all unavailable simulators?" : "Permanently delete Docker items and unavailable simulators?") : "Permanently delete the selected Docker items?").font(KitFont.bodyMedium).foregroundStyle(KitColor.text)
                            Text(warning).font(KitFont.detail).foregroundStyle(KitColor.red)
                        } else {
                            Text("Clean up \(Fmt.bytes(model.selectedBytes))?").font(KitFont.bodyMedium).foregroundStyle(KitColor.text)
                        }
                        if folders > 0 {
                            Text("\(folders) \(folders == 1 ? "folder goes" : "folders go") to the Trash.").font(KitFont.detail).foregroundStyle(KitColor.text2)
                        }
                        Text(commands.joined(separator: ", ")).font(.system(size: 11).monospacedDigit()).foregroundStyle(KitColor.text2).lineLimit(model.selectedSimulators ? nil : 1)
                    }
                }
                Spacer()
                Button("Cancel") { model.confirmation = nil }.buttonStyle(.kitSecondary).keyboardShortcut(.cancelAction)
                if model.confirmation == .freeSpace {
                    Button("Delete permanently") { model.confirmFreeSpace() }.buttonStyle(.kitDestructive)
                } else if commands.isEmpty {
                    Button("Move to Trash") { model.confirmCleanup() }.buttonStyle(.kitPrimary).keyboardShortcut(.defaultAction)
                } else if model.confirmation == .review {
                    Button("Continue") { model.confirmCleanup() }.buttonStyle(.kitPrimary).keyboardShortcut(.defaultAction)
                } else {
                    Button("Delete permanently") { model.confirmCleanup() }.buttonStyle(.kitDestructive)
                }
            }
            .padding(.horizontal, KitSpace.xl).frame(minHeight: commands.isEmpty ? 72 : (folders > 0 ? 100 : 86))
            .background(KitColor.well)
        }
        .background(KitColor.window)
    }
}

/// QA renders only: shows where the real traffic lights sit.
struct QALights: View {
    var body: some View {
        HStack(spacing: 8) { ForEach(0..<3, id: \.self) { _ in Circle().fill(KitColor.unlit).frame(width: 12, height: 12) } }.padding(.leading, 20)
    }
}

/// First window open of a session: the top hairline lights in the accent from the centre outward, then settles away.
struct PowerHairline: View {
    var on: Bool
    @State private var grow = false
    @State private var fade = false
    @Environment(\.kitAccent) private var accent
    var body: some View {
        Rectangle().fill(accent).frame(height: 1)
            .scaleEffect(x: grow ? 1 : 0.001).opacity(fade ? 0 : (grow ? 1 : 0))
            .allowsHitTesting(false)
            .onChange(of: on) { _, now in
                guard now else { return }
                withAnimation(.easeOut(duration: 0.25)) { grow = true }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { withAnimation(.easeOut(duration: 0.3)) { fade = true } }
            }
    }
}
