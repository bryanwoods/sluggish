import AppKit
import Combine

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
let scenario = CommandLine.arguments.drop { $0 != "--scenario" }.dropFirst().first
if CommandLine.arguments.contains("--demo") {
    let s = demoSnapshot(scenario: scenario)
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
    let s = scenario == nil ? sample() : demoSnapshot(scenario: scenario)
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
    let s = CommandLine.arguments.contains("--live") ? sample() : demoSnapshot(scenario: scenario)
    MainActor.assumeIsolated {
        NSApplication.shared.appearance = NSAppearance(named: CommandLine.arguments.contains("--dark") ? .darkAqua : .aqua)
        let model = Model()
        model.snap = s
        model.found = findings(s)
        let panel = AppKitPanel(model: model, statusItem: false)
        panel.forceOpen = CommandLine.arguments.contains("--open")
        snapshot(panel.content(), to: CommandLine.arguments[i + 1])
    }
    exit(0)
}
MainActor.assumeIsolated {
    NSApplication.shared.setActivationPolicy(.accessory)
    let panel = AppKitPanel(model: Model())
    // --exercise opens the panel, opens the first card's details, and closes it again, so memory after use can be measured unattended.
    if CommandLine.arguments.contains("--exercise") {
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { panel.toggle() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) {
            if let f = panel.model.found.first(where: { $0.evidence != nil }) ?? panel.model.found.first {
                panel.model.guess(for: f)
                panel.model.openCard = f.id
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 9) { panel.close() }
    }
    withExtendedLifetime(panel) { NSApplication.shared.run() }
}

func footprintMB() -> Double { Double(usage(getpid())!.ri_phys_footprint) / 1048576 }

final class Backdrop: NSView {
    override func draw(_ dirtyRect: NSRect) {
        NSColor.windowBackgroundColor.setFill()
        dirtyRect.fill()
    }
}

// Renders the panel to a PNG at 2x, so the design can be checked without a screenshot.
@MainActor func snapshot(_ view: NSView, to path: String) {
    let host = Backdrop()
    host.addSubview(view)
    view.translatesAutoresizingMaskIntoConstraints = false
    NSLayoutConstraint.activate([view.leadingAnchor.constraint(equalTo: host.leadingAnchor), view.trailingAnchor.constraint(equalTo: host.trailingAnchor),
                                 view.topAnchor.constraint(equalTo: host.topAnchor), view.bottomAnchor.constraint(equalTo: host.bottomAnchor)])
    host.frame.size = host.fittingSize
    let window = NSWindow(contentRect: host.frame, styleMask: .borderless, backing: .buffered, defer: false)
    window.appearance = NSApplication.shared.appearance
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

struct Note {
    var text: String
    var icon = "checkmark.circle.fill"
    var color = NSColor.systemGreen
    var at = Date()

    static func result(_ err: String?, ok: String) -> Note {
        err.map { Note(text: $0, icon: "exclamationmark.triangle.fill", color: .systemOrange) } ?? Note(text: ok)
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
        note = Note(text: asking ? "Answer the macOS dialog…" : "Working…", icon: "hourglass", color: .secondaryLabelColor)
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
    // It runs in a child copy of Sluggish: the model framework allocates several MB that would otherwise stay in the menu bar app.
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
