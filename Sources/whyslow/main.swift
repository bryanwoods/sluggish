import ServiceManagement
import SwiftUI

if CommandLine.arguments.contains("--selftest") {
    selfTest()
    exit(0)
}
if let i = CommandLine.arguments.firstIndex(of: "--explain"), i + 1 < CommandLine.arguments.count {
    Task {
        print(await explain(CommandLine.arguments[i + 1]) ?? "", terminator: "")
        exit(0)
    }
    dispatchMain()
}
if CommandLine.arguments.contains("--demo") {
    let s = demoSnapshot()
    print(text(s, findings(s)), terminator: "")
    exit(0)
}
if CommandLine.arguments.contains("--bench") {
    var phases: [String: [Double]] = [:]
    var order: [String] = []
    var childStart = rusage()
    getrusage(RUSAGE_CHILDREN, &childStart)
    print(String(format: "footprint before any check: %.1f MB", footprintMB()))
    for run in 1...5 {
        benchMarks = []
        let s = sample(seconds: 0.5)
        _ = findings(s)
        if run == 1 { print(String(format: "footprint after check 1:    %.1f MB", footprintMB())) }
        for (i, m) in benchMarks!.enumerated().dropFirst() { phases[m.0, default: []].append(m.1 - benchMarks![i - 1].1) }
        if order.isEmpty { order = benchMarks!.dropFirst().map(\.0) }
    }
    var child = rusage()
    getrusage(RUSAGE_CHILDREN, &child)
    let childMs = Double(child.ru_utime.tv_sec + child.ru_stime.tv_sec - childStart.ru_utime.tv_sec - childStart.ru_stime.tv_sec) * 1000
        + Double(child.ru_utime.tv_usec + child.ru_stime.tv_usec - childStart.ru_utime.tv_usec - childStart.ru_stime.tv_usec) / 1000
    print("median CPU ms per check, by phase:")
    var total = 0.0
    for name in order {
        let v = phases[name, default: [0]].sorted()[phases[name, default: [0]].count / 2]
        total += v
        print("  " + name.padding(toLength: 16, withPad: " ", startingAt: 0) + String(format: "%7.1f", v))
    }
    print(String(format: "footprint now:    %7.1f MB", footprintMB()))
    print(String(format: "  total           %7.1f\nchild processes:  %7.1f ms per check\npeak footprint:   %7.1f MB", total, childMs / 5, Double(usage(getpid())!.ri_lifetime_max_phys_footprint) / 1048576))
    exit(0)
}
if CommandLine.arguments.contains("--print") {
    let s = sample()
    let fs = findings(s)
    guard CommandLine.arguments.contains("--ai") else {
        print(text(s, fs), terminator: "")
        exit(0)
    }
    Task {
        var guesses: [String: String] = [:]
        for e in fs.compactMap(\.evidence) { guesses[e] = await explain(e) }
        print(text(s, fs, guesses: guesses), terminator: "")
        exit(0)
    }
    dispatchMain()
}
if let i = CommandLine.arguments.firstIndex(of: "--snapshot"), i + 1 < CommandLine.arguments.count {
    let s = CommandLine.arguments.contains("--live") ? sample() : demoSnapshot()
    MainActor.assumeIsolated {
        let model = Model()
        model.snap = s
        model.found = findings(s)
        snapshot(ReportView(model: model, openCards: CommandLine.arguments.contains("--open")), to: CommandLine.arguments[i + 1],
                 dark: CommandLine.arguments.contains("--dark"))
    }
    exit(0)
}
WhySlow.main()

func footprintMB() -> Double { Double(usage(getpid())!.ri_phys_footprint) / 1048576 }

// Renders the panel to a PNG at 2x, so the design can be checked without a screenshot.
@MainActor func snapshot(_ view: some View, to path: String, dark: Bool) {
    _ = NSApplication.shared
    let host = NSHostingView(rootView: view.background(Color(nsColor: .windowBackgroundColor)))
    host.frame.size = host.fittingSize
    let window = NSWindow(contentRect: host.frame, styleMask: .borderless, backing: .buffered, defer: false)
    window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
    window.contentView = host
    host.layoutSubtreeIfNeeded()
    RunLoop.main.run(until: Date() + 0.2)
    host.frame.size = host.fittingSize
    window.setContentSize(host.frame.size)
    host.layoutSubtreeIfNeeded()
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(host.bounds.width * 2), pixelsHigh: Int(host.bounds.height * 2),
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = host.bounds.size
    host.cacheDisplay(in: host.bounds, to: rep)
    try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
}

struct WhySlow: App {
    @StateObject private var model = Model()

    init() { NSApplication.shared.setActivationPolicy(.accessory) }

    var body: some Scene {
        MenuBarExtra("whyslow", systemImage: "gauge.with.dots.needle.67percent") {
            ReportView(model: model)
        }
        .menuBarExtraStyle(.window)
    }
}

struct Note {
    var text: String
    var icon = "checkmark.circle.fill"
    var color = Color.green
    var at = Date()

    static func result(_ err: String?, ok: String) -> Note {
        err.map { Note(text: $0, icon: "exclamationmark.triangle.fill", color: .orange) } ?? Note(text: ok)
    }
}

@MainActor
final class Model: ObservableObject {
    @Published var snap: Snapshot?
    @Published var found: [Finding] = []
    @Published var busy = false
    @Published var note: Note?
    @Published var guesses: [String: String] = [:]
    @Published var openCard: String?
    private var asked: Set<String> = []
    private var termed: Set<pid_t> = []

    func refresh(fresh: Bool = false) {
        guard !busy else { return }
        busy = true
        if fresh { forgetCaches() }
        let termed = termed
        Task.detached {
            let s = sample()
            let fs = findings(s, termed: termed)
            await MainActor.run { self.show(s, fs, note: self.note.flatMap { Date().timeIntervalSince($0.at) < 120 ? $0 : nil }) }
        }
    }

    func run(_ a: Action, on f: Finding) {
        guard !busy else { return }
        switch a.fix {
        case .openSettings, .openTab:
            note = .result(a.fix.apply(), ok: a.fix.done!)
            forgetCaches()
            return
        default:
            break
        }
        busy = true
        let asking = if case .askAutomation = a.fix { true } else { false }
        note = Note(text: asking ? "Answer the macOS dialog…" : "Working…", icon: "hourglass", color: .secondary)
        termed.formUnion(a.fix.pids)
        let termed = termed
        Task.detached {
            let err = a.fix.apply()
            forgetCaches()
            let s = sample()
            let fs = findings(s, termed: termed)
            let after = fs.first { $0.id == f.id }
            let note = Note.result(err, ok: a.fix.done
                ?? (after == nil ? "Done. Freed \(size(f.bytes))."
                : after!.bytes < f.bytes ? "Done. Freed \(size(f.bytes - after!.bytes))."
                : "Done, but it is still there. Refresh in a few seconds."))
            await MainActor.run { self.show(s, fs, note: note) }
        }
    }

    func copyReport() {
        guard let s = snap else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text(s, found, guesses: guesses), forType: .string)
        note = Note(text: "Copied the report. Paste it into a message to share it.")
    }

    // The on-device model runs only when someone opens a card's details, because that is the only place its line shows.
    // It runs in a child copy of whyslow: the model framework allocates several MB that would otherwise stay in the menu bar app.
    func guess(for f: Finding) {
        guard let e = f.evidence, !asked.contains(e), let me = Bundle.main.executablePath else { return }
        asked.insert(e)
        Task.detached {
            let line = finish(start(me, ["--explain", e]))
            await MainActor.run { if !line.isEmpty { self.guesses[e] = line } }
        }
    }

    private func show(_ s: Snapshot, _ fs: [Finding], note: Note?) {
        var s = s
        s.procs = [:]
        s.children = [:]
        snap = s
        found = fs
        self.note = note
        busy = false
        // A check allocates and frees a few MB; give the free pages back so they do not count against the app.
        malloc_zone_pressure_relief(nil, 0)
    }
}

struct ReportView: View {
    @ObservedObject var model: Model
    var openCards = false
    @AppStorage("prTitles") private var prTitles = false
    @State private var showLeftovers = false
    @State private var showMore = false
    @State private var listHeight: CGFloat = 0
    @State private var openedAt = Date()

    var body: some View {
        let main = model.found.filter { $0.bucket != .leftovers }
        let left = model.found.filter { $0.bucket == .leftovers }
        VStack(alignment: .leading, spacing: 12) {
            if let s = model.snap {
                let v = verdict(s, model.found)
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: v.ok ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                        .font(.title2).foregroundStyle(v.ok ? .green : .orange)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(v.headline).font(.headline)
                        if let c = v.cause { Text(c).font(.subheadline).foregroundStyle(.secondary) }
                    }
                }
                HStack(spacing: 6) {
                    Chip(icon: "memorychip", text: ["Memory OK", "Memory OK", "Memory tight", "Memory tight", "Memory full"][Int(min(max(s.pressure, 0), 4))], warn: s.pressure >= 2)
                    Chip(icon: "cpu", text: "Processor \(Int((s.cpuBusy * 100).rounded()))%", warn: s.cpuBusy > 0.8)
                    Chip(icon: "internaldrive", text: "\(size(UInt64(max(s.diskFree, 0)))) free", warn: s.diskFree < 20 << 30)
                }
            } else {
                HStack(spacing: 8) { ProgressView().controlSize(.small); Text("Checking your Mac…").font(.headline) }
            }
            if let n = model.note {
                Label { Text(n.text).bold() } icon: { Image(systemName: n.icon).foregroundStyle(n.color) }
                    .font(.callout).padding(8).frame(maxWidth: .infinity, alignment: .leading)
                    .background(n.color.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
            }
            // The header and footer stay put; the cards scroll, capped to the screen height.
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(main.prefix(3)) { CardView(f: $0, model: model, forceOpen: openCards) }
                    if main.count > 3 {
                        Fold(title: "More causes", info: "\(main.count - 3)", open: $showMore)
                        if showMore || openCards { ForEach(main.dropFirst(3)) { CardView(f: $0, model: model, forceOpen: openCards) } }
                    }
                    if !left.isEmpty {
                        Fold(title: "Left running", info: "\(left.count) · \(size(left.reduce(0) { $0 + $1.bytes }))", open: $showLeftovers)
                        if showLeftovers || openCards { ForEach(left) { CardView(f: $0, model: model, forceOpen: openCards) } }
                    }
                }
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { listHeight = $0 }
            }
            .frame(height: min(listHeight, (NSScreen.main?.visibleFrame.height ?? 800) - 260))
            Divider()
            HStack(spacing: 10) {
                if model.busy {
                    ProgressView().controlSize(.mini)
                    Text("Checking…").font(.caption).foregroundStyle(.secondary)
                } else if let s = model.snap {
                    // Worked out when the panel opens, not on a timer: a timer would wake the Mac while the panel is closed.
                    let age = openedAt.timeIntervalSince(s.now)
                    Text(age < 10 ? "Updated just now" : "Updated \(ago(age)) ago").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button { model.refresh(fresh: true) } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.borderless).disabled(model.busy).help("Check again")
                Menu {
                    Button("Copy report") { model.copyReport() }
                    Toggle("Open at login", isOn: Binding(
                        get: { SMAppService.mainApp.status == .enabled },
                        set: { on in if on { try? SMAppService.mainApp.register() } else { try? SMAppService.mainApp.unregister() } }))
                    if ghBin != nil { Toggle("Show pull request titles", isOn: $prTitles) }
                    Divider()
                    Button("Quit whyslow") { NSApp.terminate(nil) }
                } label: { Image(systemName: "ellipsis.circle") }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            }
        }
        .padding(14)
        .frame(width: 400)
        .onChange(of: prTitles) { model.refresh() }
        .onAppear {
            openedAt = Date()
            if model.snap.map({ openedAt.timeIntervalSince($0.now) > 10 }) ?? true { model.refresh() }
        }
    }
}

struct Fold: View {
    var title: String
    var info: String
    @Binding var open: Bool

    var body: some View {
        Button { withAnimation(.snappy) { open.toggle() } } label: {
            HStack(spacing: 6) {
                Image(systemName: "chevron.right").font(.caption.bold()).rotationEffect(.degrees(open ? 90 : 0))
                Text(title).font(.callout.weight(.semibold))
                Text(info).font(.callout).foregroundStyle(.secondary)
                Spacer()
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

struct Chip: View {
    var icon: String
    var text: String
    var warn: Bool

    var body: some View {
        Label(text, systemImage: icon).font(.caption)
            .padding(.horizontal, 8).padding(.vertical, 3)
            .foregroundStyle(warn ? Color.orange : .secondary)
            .background((warn ? Color.orange : Color.secondary).opacity(0.13), in: Capsule())
    }
}

struct CardView: View {
    var f: Finding
    @ObservedObject var model: Model
    var forceOpen = false
    var open: Bool { forceOpen || model.openCard == f.id }

    var body: some View {
        let primary = f.steps.compactMap(\.action).first ?? f.actions.first
        HStack(alignment: .top, spacing: 10) {
            Group {
                if f.icon.hasPrefix("/") {
                    Image(nsImage: NSWorkspace.shared.icon(forFile: f.icon)).resizable()
                } else {
                    Image(systemName: f.icon).font(.system(size: 17)).foregroundStyle(.secondary)
                }
            }
            .frame(width: 28, height: 28)
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(f.title).font(.callout.weight(.semibold)).fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 4)
                    if let m = f.metric { Text(m).font(.caption.monospacedDigit()).foregroundStyle(.secondary).fixedSize() }
                }
                Text(f.summary).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 10) {
                    if let a = primary {
                        Button(a.label) { model.run(a, on: f) }
                            .buttonStyle(.borderedProminent).controlSize(.small).disabled(model.busy).help(a.fix.command)
                    }
                    Button(open ? "Less" : "Details") {
                        if !open { model.guess(for: f) }
                        withAnimation(.snappy) { model.openCard = open ? nil : f.id }
                    }
                        .buttonStyle(.link).controlSize(.small)
                }
                .padding(.top, 3)
                if open { details(primary) }
            }
        }
        .padding(10)
        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 10))
    }

    @ViewBuilder func details(_ primary: Action?) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if let g = f.evidence.flatMap({ model.guesses[$0] }) {
                Label(g, systemImage: "sparkles").font(.callout)
                    .help("A guess by the on-device AI model, from the facts below. It can be wrong.")
            }
            Text(f.detail).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            ForEach(Array(f.steps.enumerated()), id: \.offset) { i, step in
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text("\(i + 1).").font(.callout).monospacedDigit().foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(step.text).font(.callout).fixedSize(horizontal: false, vertical: true)
                        if let a = step.action, a.id != primary?.id {
                            Button(a.label) { model.run(a, on: f) }.controlSize(.small).disabled(model.busy).help(a.fix.command)
                        }
                    }
                }
            }
            ForEach(f.actions.filter { $0.id != primary?.id }) { a in
                Button(a.label) { model.run(a, on: f) }.controlSize(.small).disabled(model.busy).help(a.fix.command)
            }
        }
        .padding(.top, 4)
    }
}
