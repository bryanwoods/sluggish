import AppKit
import Foundation

enum Bucket: String, CaseIterable {
    case now = "BUSY NOW"
    case always = "ALWAYS ON"
    case leftovers = "FORGOTTEN"
}

enum Fix: Hashable {
    case signal(pid_t, Int32, started: Date)
    case quitApp(String)
    case dockerStop(String)
    case simShutdown(String)
    case openSettings(String)
    case askAutomation(String)
    case closeDuplicateTabs(String)
    case openTab(String, String)
    case all([Fix])

    var command: String {
        switch self {
        case let .openSettings(id): return "open x-apple.systempreferences:\(id)"
        case let .askAutomation(id): return "ask macOS to let whyslow read the tab addresses of \(id)"
        case let .closeDuplicateTabs(id): return "close the duplicate tabs in \(id), keep the first copy"
        case let .openTab(id, url): return "open \(url) in \(id)"
        case let .signal(pid, sig, _): return "kill -\(sig == SIGKILL ? "KILL" : "TERM") \(pid)"
        case let .quitApp(bundle): return "Cmd-Q \(bundle)"
        case let .dockerStop(id): return "docker stop \(id)"
        case let .simShutdown(udid): return "simctl shutdown \(udid)"
        case let .all(fixes): return fixes.map(\.command).joined(separator: "; ")
        }
    }

    // The success message, for fixes where "Freed N MB" does not fit.
    var done: String? {
        switch self {
        case .askAutomation: return "Allowed. The card below now shows tabs that you can close."
        case .closeDuplicateTabs: return "Closed the duplicate tabs. To bring one back, press Cmd-Shift-T in the browser."
        case .openTab: return "The page is open in your browser."
        case .openSettings: return "System Settings is open."
        default: return nil
        }
    }

    var pids: [pid_t] {
        switch self {
        case let .signal(pid, _, _): return [pid]
        case let .all(fixes): return fixes.flatMap(\.pids)
        default: return []
        }
    }

    func apply() -> String? {
        switch self {
        case let .signal(pid, sig, started):
            guard pid > 1, let now = bsdInfo(pid), now.pbi_uid == getuid(),
                  Double(now.pbi_start_tvsec) == started.timeIntervalSince1970
            else { return "Not done: the process is gone, belongs to another user, or was replaced." }
            return kill(pid, sig) == 0 ? nil : String(cString: strerror(errno))
        case let .quitApp(bundle):
            NSRunningApplication.runningApplications(withBundleIdentifier: bundle).forEach { $0.terminate() }
            return nil
        case let .dockerStop(id):
            // Docker waits up to 10 seconds for a container to stop before it answers.
            return dockerAPI("POST", "/containers/\(id)/stop", timeout: 15) == nil ? "Not done: Docker did not stop the container." : nil
        case let .simShutdown(udid):
            guard let bin = simctlBin, let h = start(bin, ["shutdown", udid]) else { return "Not done: Xcode is not installed." }
            finish(h)
            return h.0.terminationStatus == 0 ? nil : "Not done: the simulator did not shut down."
        case let .openSettings(id):
            return NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:\(id)")!) ? nil : "Not done: System Settings did not open."
        case let .askAutomation(id):
            return automation(id, ask: true) == .allowed ? nil : "Not allowed. You can change this later in Privacy & Security > Automation."
        case let .closeDuplicateTabs(id):
            return closeDuplicates(in: id) ? nil : "Not done: the browser did not answer."
        case let .openTab(id, url):
            return openPage(url, in: id) ? nil : "Not done: the browser did not open the page."
        case let .all(fixes):
            let errors = fixes.compactMap { $0.apply() }
            return errors.isEmpty ? nil : errors.joined(separator: "\n")
        }
    }
}

struct Action: Identifiable {
    var label: String
    var fix: Fix
    var id: String { fix.command }
}

struct Finding: Identifiable {
    var id: String
    var bucket: Bucket
    var title: String
    var detail: String
    var bytes: UInt64 = 0
    var actions: [Action] = []
    var evidence: String? = nil
    var steps: [Step] = []
    var subject = ""
    var summary = ""
    var metric: String? = nil
    var icon = "exclamationmark.circle"
    var impact = 0.0

    // icon is an SF Symbol name, or the path of an .app whose own icon is shown.
    func card(_ subject: String, _ summary: String, metric: String? = nil, icon: String, impact: Double) -> Finding {
        var f = self
        (f.subject, f.summary, f.metric, f.icon, f.impact) = (subject, summary, metric, icon, impact)
        return f
    }
}

// The one line at the top of the panel: what is wrong, and which card matters most.
func verdict(_ s: Snapshot, _ fs: [Finding]) -> (headline: String, cause: String?, ok: Bool) {
    let main = fs.filter { $0.bucket != .leftovers }
    if s.thermal == .serious || s.thermal == .critical { return ("Your Mac is too hot.", nil, false) }
    if s.diskTotal > 0, s.diskFree < 20 << 30 { return ("Your disk is almost full.", nil, false) }
    if s.pressure >= 2, let top = main.filter({ $0.bytes > 0 }).max(by: { $0.bytes < $1.bytes }) {
        return ("Your Mac is short on memory.", "The biggest cause: \(top.subject).", false)
    }
    if s.cpuBusy > 0.8, let top = main.filter({ $0.bucket == .now }).max(by: { $0.impact < $1.impact }) {
        return ("Your Mac's processor is very busy.", "The biggest cause: \(top.subject).", false)
    }
    guard let top = main.max(by: { $0.impact < $1.impact }) else { return ("Your Mac looks fine right now.", nil, true) }
    return ("A few things slow your Mac down.", "The biggest cause: \(top.subject).", false)
}

private func pct(_ cpu: Double, _ s: Snapshot) -> String { "\(Int((cpu / Double(max(s.cores, 1)) * 100).rounded()))% CPU" }
private func ofRam(_ b: UInt64, _ s: Snapshot) -> Double { Double(b) / Double(max(s.ram, 1)) }

struct Step {
    var text: String
    var action: Action? = nil
}

private let siteNames = ["calendar.google.com": "Google Calendar", "mail.google.com": "Gmail", "docs.google.com": "Google Docs",
                         "meet.google.com": "Google Meet", "drive.google.com": "Google Drive", "github.com": "GitHub", "youtube.com": "YouTube",
                         "claude.ai": "Claude", "chatgpt.com": "ChatGPT", "figma.com": "Figma", "linear.app": "Linear", "notion.so": "Notion",
                         "app.slack.com": "Slack", "reddit.com": "Reddit", "x.com": "X", "amazon.com": "Amazon"]

func findings(_ s: Snapshot, termed: Set<pid_t> = []) -> [Finding] {
    let detectors: [(String, () -> [Finding])] = [
        ("heat", { heat(s) }), ("browsers", { browsers(s) }), ("services", { busyServices(s) }), ("disk", { lowDisk(s) }),
        ("login items", { loginApps(s) }), ("cpu", { cpuHogs(s) }), ("docker card", { docker(s) }), ("simulators", { simulators(s) }),
        ("stacks", { stacks(s, termed) }), ("test browsers", { testBrowsers(s, termed) }), ("caffeinate", { caffeinates(s, termed) }),
    ]
    return autoreleasepool { detectors.flatMap { name, detect in defer { mark(name) }; return detect() } }.sorted { ($0.impact, $1.id) > ($1.impact, $0.id) }
}

private let browserNames = ["Safari": "Safari", "Google Chrome": "Chrome", "Arc": "Arc", "Firefox": "Firefox", "Microsoft Edge": "Edge",
                            "Brave Browser": "Brave", "Opera": "Opera", "Vivaldi": "Vivaldi", "Orion": "Orion", "Zen": "Zen"]
private let webKitPages = ["/com.apple.WebKit.WebContent", "/com.apple.WebKit.Networking", "/com.apple.WebKit.GPU"]

private func browserOf(_ p: Proc, safariRuns: Bool) -> String? {
    if let app = p.app, browserNames[app] != nil { return app }
    // ponytail: every WebKit page process counts toward Safari, so Mail and other WebKit apps are included; the responsible-pid API would split them
    return safariRuns && webKitPages.contains(where: p.path.hasSuffix) ? "Safari" : nil
}

private func browsers(_ s: Snapshot) -> [Finding] {
    let safariRuns = s.procs.values.contains { $0.app == "Safari" }
    let groups = Dictionary(grouping: s.procs.values.filter { browserOf($0, safariRuns: safariRuns) != nil }) { browserOf($0, safariRuns: safariRuns)! }
    return groups.sorted { $0.key < $1.key }.compactMap { app, procs in
        let mem = procs.reduce(0) { $0 + $1.footprint }
        let cpu = procs.reduce(0) { $0 + $1.cpu }
        guard cpu >= 1 || Double(mem) >= Double(s.ram) * 0.2 else { return nil }
        let name = browserNames[app]!
        let why = cpu >= 1
            ? "A busy page, such as a video or a large web app, takes processor time from your other apps."
            : "That is \(Int(Double(mem) / Double(max(s.ram, 1)) * 100))% of your Mac's memory. When memory runs short, macOS moves data to the disk, and everything gets slower."
        let bundleID = s.apps.first { $0.path.hasSuffix("/\(app).app") }?.bundleID
        var steps: [Step] = []
        if let id = bundleID, scriptableBrowsers.contains(id) {
            switch s.access[id] {
            case .allowed?:
                if let t = s.tabs[id], t.duplicates > 0 {
                    steps.append(Step(text: "\(t.duplicates == 1 ? "1 tab shows" : "\(t.duplicates) tabs show") the same page as another tab.",
                                      action: Action(label: "Close \(plural(t.duplicates, "duplicate"))", fix: .closeDuplicateTabs(id))))
                }
                if let t = s.tabs[id], !t.piles.isEmpty {
                    steps.append(Step(text: "Many tabs are from the same site: \(list(t.piles.map { "\($0.n) from \(siteNames[$0.host] ?? $0.host)" })). Close the ones that you are done with."))
                }
            case .notAsked?:
                steps.append(Step(text: "whyslow can look at your open tabs and find the ones that you can close. macOS calls this permission “control”.",
                                  action: Action(label: "See my open tabs", fix: .askAutomation(id))))
            case .denied?:
                steps.append(Step(text: "To find tabs that you can close, turn on \(name) under whyslow in Privacy & Security > Automation.",
                                  action: Action(label: "Open Automation settings", fix: .openSettings("com.apple.preference.security?Privacy_Automation"))))
            default:
                break
            }
        }
        if steps.isEmpty { steps.append(Step(text: "Close the tabs that you do not need.")) }
        // ponytail: Memory Saver only for Chrome; Edge and Brave have the same feature at their own settings URLs
        if bundleID == "com.google.Chrome", s.access["com.google.Chrome"] == .allowed, (s.memorySaver ?? 0) == 0 {
            steps.append(Step(text: "Turn on Memory Saver\(s.memorySaver == nil ? ", if it is off" : ""). Chrome then puts tabs that you have not used for a while to sleep.",
                              action: Action(label: "Open Chrome settings", fix: .openTab("com.google.Chrome", "chrome://settings/performance"))))
        }
        steps.append(Step(text: "Quit and open \(name) again. This frees memory that \(name) holds on to over time.",
                          action: bundleID.map { Action(label: "Quit \(name)", fix: .quitApp($0)) }))
        var found: [String] = []
        if let id = bundleID, s.access[id] == .allowed, let t = s.tabs[id] {
            if t.duplicates > 0 { found.append(plural(t.duplicates, "duplicate tab")) }
            if let p = t.piles.first { found.append("\(p.n) \(siteNames[p.host] ?? p.host) tabs") }
        }
        let summary = cpu >= 1 ? "A busy page takes processor time from your other apps."
            : !found.isEmpty ? "\(list(found)) are open."
            : s.access[bundleID ?? ""] == .notAsked ? "Each open tab uses memory. whyslow can find the tabs that you can close."
            : "Each open tab uses memory. Close the tabs that you do not need."
        return Finding(
            id: "browser-app:\(app)", bucket: cpu >= 1 ? .now : .always,
            title: cpu >= 1 ? "\(name) is working hard" : "\(name) uses \(size(mem)) of memory",
            detail: "\(why) \(name) runs \(plural(procs.count, "process")), because each tab and extension gets its own.",
            bytes: mem, steps: steps)
            .card(name, summary, metric: cpu >= 1 ? pct(cpu, s) : "\(Int(ofRam(mem, s) * 100))% of memory",
                  icon: s.apps.first { $0.path.hasSuffix("/\(app).app") }?.path ?? "globe",
                  impact: max(ofRam(mem, s), cpu / Double(max(s.cores, 1))))
    }
}

private let services: [(names: Set<String>, title: String, why: String, fix: String, settings: (label: String, id: String)?)] = [
    (["photoanalysisd", "mediaanalysisd", "photolibraryd"], "Photos is analyzing your pictures",
     "Photos scans your library to find faces, objects, and text. This takes a lot of processor power, mostly after you import many photos or update macOS.",
     "It stops by itself when it is done. To let it finish sooner, leave the Mac on and plugged in when you do not use it.", nil),
    (["bird", "cloudd", "fileproviderd"], "iCloud is syncing your files",
     "iCloud Drive uploads and downloads your files. This uses the processor and the network, mostly after you add many files or set up a new Mac.",
     "It stops by itself when it is done. To see what syncs, open your Apple Account settings and choose iCloud.",
     ("Open Apple Account settings", "com.apple.systempreferences.AppleIDSettings")),
    (["mdworker_shared", "mdworker", "corespotlightd"], "Spotlight is indexing your files",
     "Spotlight reads new and changed files so that you can search them. This is busy after a macOS update or after you add many files.",
     "It stops by itself when it is done. To skip a folder, add it to the privacy list in Spotlight settings.",
     ("Open Spotlight settings", "com.apple.Spotlight-Settings.extension")),
]

private func busyServices(_ s: Snapshot) -> [Finding] {
    services.compactMap { svc in
        let cpu = s.procs.values.filter { svc.names.contains($0.name) && $0.uid == getuid() }.reduce(0) { $0 + $1.cpu }
        guard cpu >= 0.5 else { return nil }
        let subject = String(svc.title.split(separator: " ")[0])
        return Finding(id: "service:\(svc.title)", bucket: .now, title: svc.title, detail: "\(svc.why) \(svc.fix)",
                       actions: svc.settings.map { [Action(label: $0.label, fix: .openSettings($0.id))] } ?? [])
            .card(subject, "This is normal, and it stops by itself when it is done.", metric: pct(cpu, s),
                  icon: ["Photos": "photo.on.rectangle.angled", "iCloud": "icloud", "Spotlight": "magnifyingglass"][subject] ?? "gearshape",
                  impact: cpu / Double(max(s.cores, 1)))
    }
}

private func heat(_ s: Snapshot) -> [Finding] {
    guard s.thermal == .serious || s.thermal == .critical else { return [] }
    let critical = s.thermal == .critical
    return [Finding(
        id: "heat", bucket: .now,
        title: critical ? "Your Mac is very hot, so macOS slows it down a lot" : "Your Mac is hot, so macOS slows it down",
        detail: "To protect the hardware, macOS lowers the processor speed when the Mac gets too hot. Common causes are an app that works hard, a warm room, or blocked air vents, for example a laptop on a bed or a sofa. Quit the apps that work hard, and put the Mac on a hard, flat surface. If you saw “kernel_task” in Activity Monitor, this is the reason.")
        .card("Heat", "Quit apps that work hard, and keep the air vents clear.", metric: critical ? "Very hot" : "Hot",
              icon: "thermometer.high", impact: 1)]
}

private func lowDisk(_ s: Snapshot) -> [Finding] {
    guard s.diskTotal > 0, s.diskFree < 20 << 30 else { return [] }
    return [Finding(
        id: "disk", bucket: .always, title: "Your disk is almost full",
        detail: "Only \(size(UInt64(max(s.diskFree, 0)))) of \(size(UInt64(s.diskTotal))) is free. When memory runs short, macOS moves data to the disk. With little free space, this gets slow, and apps can freeze. Storage settings shows what uses the most space, so you can remove files you do not need.",
        actions: [Action(label: "Open Storage settings", fix: .openSettings("com.apple.settings.Storage"))])
        .card("A full disk", "A full disk makes the whole Mac slow when memory runs short.",
              metric: "\(size(UInt64(max(s.diskFree, 0)))) free", icon: "internaldrive", impact: 0.9)]
}

// Login items are not readable without root, so count non-Apple apps that run in the background or started within 3 minutes of login.
private func loginApps(_ s: Snapshot) -> [Finding] {
    let login = s.procs.values.filter { $0.name == "loginwindow" && $0.uid == getuid() }.map(\.started).min()
    var mem: [String: UInt64] = [:]
    for a in s.apps where !a.bundleID.hasPrefix("com.apple.") && a.pid != getpid() {
        guard a.path.hasSuffix(".app"), let p = s.procs[a.pid], let r = a.path.range(of: ".app") else { continue }
        let helper = a.path.contains("/Contents/Library/LoginItems/")
        let atLogin = login.map { p.started >= $0 && p.started < $0 + 180 } ?? false
        guard r.upperBound == a.path.endIndex || helper, a.background || atLogin else { continue }
        let bundle = String(a.path[..<r.upperBound])
        let name = helper ? appName(a.path + "/Contents/MacOS/") ?? a.name : a.name
        mem[name] = s.procs.values.filter { $0.path.hasPrefix(bundle + "/") }.reduce(0) { $0 + $1.footprint }
    }
    guard mem.count >= 6 else { return [] }
    let names = mem.sorted { $0.value > $1.value }.map(\.key)
    let total = mem.values.reduce(0, +)
    let shown = names.count > 4 ? names.prefix(4).joined(separator: ", ") + ", and \(names.count - 4) more" : list(names)
    return [Finding(
        id: "login", bucket: .always, title: "\(names.count) apps start by themselves",
        detail: "\(shown) open when you log in or keep running in the background. Together they use \(size(total)) of memory, and they make login slower. Turn off the ones you do not need in Login Items.",
        bytes: total,
        actions: [Action(label: "Open Login Items settings", fix: .openSettings("com.apple.LoginItems-Settings.extension"))])
        .card("Apps that start at login", "\(names.prefix(2).joined(separator: ", ")), and \(names.count - 2) more open when you log in.",
              metric: size(total), icon: "power", impact: ofRam(total, s))]
}

private func cpuHogs(_ s: Snapshot) -> [Finding] {
    let safariRuns = s.procs.values.contains { $0.app == "Safari" }
    let serviceNames = services.reduce(Set<String>()) { $0.union($1.names) }
    var groups: [String: (cpu: Double, n: Int, root: Proc, app: String?)] = [:]
    let vm = dockerVM(s)?.pid
    for p in s.procs.values where p.cpu > 0.01 && p.pid != getpid() && p.pid != vm && browserOf(p, safariRuns: safariRuns) == nil && !serviceNames.contains(p.name) {
        let app = p.app
        let root = app == nil ? starter(p, s).root : p
        let key = app ?? "pid:\(root.pid)"
        let g = groups[key]
        groups[key] = ((g?.cpu ?? 0) + p.cpu, (g?.n ?? 0) + 1, g?.root ?? root, app)
    }
    return groups.filter { $0.value.cpu >= 1 }.sorted { $0.value.cpu > $1.value.cpu }.map { key, g in
        let impact = g.cpu / Double(max(s.cores, 1))
        if let app = g.app {
            return Finding(id: "cpu:\(key)", bucket: .now, title: "\(app) is busy", detail: "It runs \(plural(g.n, "process")).")
                .card(app, "It takes processor time from your other apps.", metric: pct(g.cpu, s),
                      icon: s.apps.first { $0.path.hasSuffix("/\(app).app") }?.path ?? "app", impact: impact)
        }
        let st = starter(g.root, s)
        let cmd = commandLine(g.root)
        let short = cmd.count > 60 ? cmd.prefix(59) + "…" : cmd
        guard let who = st.who else {
            return Finding(id: "cpu:\(key)", bucket: .now, title: "A background process is busy",
                           detail: "Its name is “\(short)”. It runs \(plural(g.n, "process")).",
                           evidence: "A background process. No app or terminal started it.\nCommand: \(cmd.prefix(300))\nPath: \(g.root.path)")
                .card(g.root.name, "Its name is “\(g.root.name)”.", metric: pct(g.cpu, s), icon: "gearshape", impact: impact)
        }
        let kind = workKind(cmd) ?? "a command"
        let title = who == "you" ? "You are running \(kind)" : "\(who) is running \(kind)"
        let repo = git(projectRoot(g.root.cwd))
        let work = st.claude.flatMap { claudeSession(pid: $0) }
        let project = repo.map { " Project: \($0.repo), branch \($0.branch)." } ?? ""
        let age = s.now.timeIntervalSince(g.root.started)
        return Finding(
            id: "cpu:\(key)", bucket: .now, title: title,
            detail: "\(startedBy(st, age, work)) The command is “\(short)”.\(project) It stops when the command ends.",
            evidence: facts(who: who, git: repo, work: work, more: ["Command: \(cmd.prefix(300))"]))
            .card(who == "you" ? "your \(kind)" : "\(kind) from \(who)", "“\(short)” started \(ago(age)) ago. It stops when it ends.",
                  metric: pct(g.cpu, s), icon: "terminal", impact: impact)
    }
}

private func workKind(_ cmd: String) -> String? {
    let c = cmd.lowercased()
    if ["test", "pytest", "jest", "vitest", "rspec"].contains(where: c.contains) { return "tests" }
    if ["build", "compile", "tsc", "webpack"].contains(where: c.contains) { return "a build" }
    if ["install", "uv sync", "bundle"].contains(where: c.contains) { return "a package install" }
    return nil
}

// The highest non-shell ancestor below whatever launched it (Claude Code, a login shell, or an app).
private func starter(_ p: Proc, _ s: Snapshot) -> (root: Proc, who: String?, claude: pid_t?) {
    let shells: Set = ["sh", "bash", "zsh", "fish", "dash", "csh", "tcsh"]
    var cur = p
    var root: Proc? = shells.contains(p.name) ? nil : p
    while let parent = s.procs[cur.ppid], parent.pid > 1 {
        if parent.name == "claude" { return (root ?? cur, "Claude Code", parent.pid) }
        if parent.name.hasPrefix("-") { return (root ?? cur, "you", nil) }
        if let app = parent.app { return (root ?? cur, app, nil) }
        cur = parent
        if !shells.contains(cur.name) { root = cur }
    }
    return (root ?? cur, nil, nil)
}

private func startedBy(_ st: (root: Proc, who: String?, claude: pid_t?), _ age: TimeInterval, _ w: ClaudeWork?) -> String {
    let when = "\(ago(age)) ago"
    switch st.who {
    case "Claude Code"?:
        let about = w?.title.map { ", in a session about “\($0)”" } ?? ""
        let pr = prTitle(w?.prRepo, w?.pr.map(String.init)).map { ", for the pull request “\($0)”" } ?? w?.pr.map { " (pull request #\($0))" } ?? ""
        return "Claude Code started it \(when)\(about)\(pr)."
    case "you"?: return "You started it in a terminal \(when)."
    case let app?: return "\(app) started it \(when)."
    case nil: return "It started \(when). The app or terminal that started it is closed."
    }
}

private let appDirs = ["/Applications/", "/System/Applications/", NSHomeDirectory() + "/Applications/"]

// Runs for every process in the scan: the cheap prefix test comes first and rejects /System and /usr paths.
func appName(_ path: String) -> String? {
    for prefix in appDirs where path.hasPrefix(prefix) {
        guard path.contains(".app/Contents/MacOS/") else { return nil }
        if let app = path.dropFirst(prefix.count).split(separator: "/").first(where: { $0.hasSuffix(".app") }) {
            return String(app.dropLast(4))
        }
    }
    return nil
}

// Docker's Linux VM. The Docker card owns its memory and its CPU, so the CPU card skips it.
// ponytail: largest Virtualization.framework VM is assumed to be Docker's; UTM/Tart users need the responsible-pid lookup
private func dockerVM(_ s: Snapshot) -> Proc? {
    guard s.procs.values.contains(where: { $0.path.contains("/Docker.app/") }) else { return nil }
    return s.procs.values.filter { $0.path.hasSuffix("/com.apple.Virtualization.VirtualMachine") }.max { $0.footprint < $1.footprint }
}

private func docker(_ s: Snapshot) -> [Finding] {
    guard let vm = dockerVM(s), vm.footprint > 1 << 30 || vm.cpu >= 1 else { return [] }
    let used = s.containers.reduce(0) { $0 + $1.mem }
    let busy = vm.cpu >= 0.5 ? " Docker also uses \(pct(vm.cpu, s)) right now, for containers that are working." : ""
    let squeezed = vm.resident * 2 < vm.footprint ? " Most of that memory is now compressed or moved to disk, and that makes the Mac slower." : ""
    let stops = s.containers.sorted { $0.mem > $1.mem }.prefix(3).map {
        Action(label: "Stop \($0.name) (\(dbKind($0.image)), \(size($0.mem)), \(onFor($0.status)))", fix: .dockerStop($0.id))
    }
    return [Finding(
        id: "docker", bucket: .always,
        title: "Docker uses \(size(vm.footprint)) of memory",
        detail: (s.containers.isEmpty ? "Docker keeps this memory for its Linux system, even when your containers need less."
            : "Your \(plural(s.containers.count, "container")) need only \(size(used)). Docker keeps the rest for itself.") + "\(squeezed)\(busy) Quit Docker to free all of it.",
        bytes: vm.footprint,
        actions: [Action(label: "Quit Docker", fix: .quitApp("com.docker.docker"))] + stops)
        .card("Docker", (s.containers.isEmpty ? "Docker keeps this memory for its Linux system." : "Your containers need only \(size(used)). Docker keeps the rest.")
                + (vm.cpu >= 0.5 ? " It also uses \(pct(vm.cpu, s)) now." : ""),
              metric: "\(Int(ofRam(vm.footprint, s) * 100))% of memory",
              icon: s.apps.first { $0.bundleID == "com.docker.docker" }?.path ?? "shippingbox",
              impact: max(ofRam(vm.footprint, s), vm.cpu / Double(max(s.cores, 1))))]
}

private func dbKind(_ image: String) -> String {
    let i = image.lowercased()
    return [("postgres", "Postgres"), ("mysql", "MySQL"), ("mariadb", "MariaDB"), ("redis", "Redis"), ("mongo", "MongoDB")]
        .first { i.contains($0.0) }?.1 ?? "container"
}

private func onFor(_ status: String) -> String {
    "on for " + status.replacingOccurrences(of: "Up ", with: "").split(separator: "(").first!.trimmingCharacters(in: .whitespaces)
}

private func testBrowsers(_ s: Snapshot, _ termed: Set<pid_t>) -> [Finding] {
    s.procs.values.filter {
        $0.ppid == 1 && $0.uid == getuid() && s.now.timeIntervalSince($0.started) > 3600 && !$0.path.contains("/Frameworks/")
            && ["/ms-playwright/", "/puppeteer/", "Chrome for Testing", "chrome-headless-shell"].contains(where: $0.path.contains)
    }.map { p in
        let mem = (descendants(p.pid, s) + [p]).reduce(0) { $0 + $1.footprint }
        let tool = p.path.contains("ms-playwright") ? "Playwright" : p.path.contains("puppeteer") ? "Puppeteer" : "A test tool"
        return Finding(
            id: "browser:\(p.pid)", bucket: .leftovers,
            title: "A test browser is still open",
            detail: "\(tool) opened it \(ago(s.now.timeIntervalSince(p.started))) ago for an automated test. The test ended but did not close it. It uses \(size(mem)).",
            bytes: mem, actions: [stop(p, termed, "Close it")],
            evidence: "Tool: \(tool). The test runner that opened it has ended.\nBrowser command: \(commandLine(p).prefix(600))")
            .card("a test browser", "\(tool) opened it \(ago(s.now.timeIntervalSince(p.started))) ago and did not close it.",
                  metric: size(mem), icon: "globe", impact: ofRam(mem, s))
    }
}

private func caffeinates(_ s: Snapshot, _ termed: Set<pid_t>) -> [Finding] {
    s.procs.values.filter { p in
        p.name == "caffeinate" && p.uid == getuid() && s.now.timeIntervalSince(p.started) > 3600
            && p.args.dropFirst().allSatisfy { $0.hasPrefix("-") && !$0.contains("t") && !$0.contains("w") }
    }.map { p in
        let flags = p.args.dropFirst().joined(separator: " ")
        let who = starter(p, s).who
        let by = who == "you" ? "You ran" : "\(who ?? "A tool") ran"
        let when = DateFormatter.localizedString(from: p.started, dateStyle: .medium, timeStyle: .short)
        return Finding(
            id: "caffeinate:\(p.pid)", bucket: .leftovers,
            title: "Your Mac is not allowed to sleep",
            detail: "\(by) “caffeinate \(flags)” on \(when). It keeps the Mac\(flags.contains("d") ? " and the screen" : "") awake until you stop it.",
            actions: [stop(p, termed, "Let the Mac sleep")])
            .card("caffeinate", "\(by) “caffeinate” \(ago(s.now.timeIntervalSince(p.started))) ago. It has no time limit.",
                  icon: "cup.and.saucer", impact: 0.001)
    }
}

private func simulators(_ s: Snapshot) -> [Finding] {
    let devices = s.procs.values.filter { $0.name == "launchd_sim" && $0.uid == getuid() }.compactMap { sim -> (name: String, udid: String, tree: [Proc])? in
        guard let plist = sim.args.dropFirst().first, let r = plist.range(of: "/Devices/") else { return nil }
        let udid = String(plist[r.upperBound...].prefix(36))
        let name = NSDictionary(contentsOfFile: String(plist[..<r.upperBound]) + udid + "/device.plist")?["name"] as? String
        return (name ?? udid, udid, descendants(sim.pid, s) + [sim])
    }.sorted { $0.name < $1.name }
    guard !devices.isEmpty else { return [] }
    let tree = devices.flatMap(\.tree)
    let mem = tree.reduce(0) { $0 + $1.footprint }
    let booted = tree.map(\.started).min()!
    let one = devices.count == 1
    return [Finding(
        id: "simulators", bucket: .always,
        title: "\(plural(devices.count, "Xcode simulator")) \(one ? "uses" : "use") \(size(mem))",
        detail: "\(list(devices.map(\.name))) \(one ? "has" : "have") been on for \(ago(s.now.timeIntervalSince(booted))). Shut \(one ? "it" : "them") down if you are not testing on \(one ? "it" : "them").",
        bytes: mem,
        actions: simctlBin == nil ? [] : devices.map { Action(label: "Shut down \($0.name)", fix: .simShutdown($0.udid)) })
        .card("Xcode simulators", "\(list(devices.map(\.name))) \(one ? "has" : "have") been on for \(ago(s.now.timeIntervalSince(booted))).",
              metric: size(mem), icon: "iphone", impact: ofRam(mem, s))]
}

// Servers that listen on a TCP port, grouped by git root, with the Docker containers whose name contains that root's name.
private func stacks(_ s: Snapshot, _ termed: Set<pid_t>) -> [Finding] {
    let servers = s.procs.values.filter { p in
        !p.ports.isEmpty && p.app == nil && p.cwd.hasPrefix(NSHomeDirectory() + "/") && !isLibrary(p.cwd)
            && s.now.timeIntervalSince(p.started) > serverAge
            && Set(s.procs[p.ppid]?.ports ?? []).isDisjoint(with: p.ports)
    }
    return Dictionary(grouping: servers) { projectRoot($0.cwd) }.sorted { $0.key < $1.key }.map { root, procs in
        let folder = URL(fileURLWithPath: root).lastPathComponent
        // ponytail: container match is by name; use compose working_dir labels if this mislinks
        let containers = folder.count >= 5 ? s.containers.filter { $0.name.contains(folder) } : []
        let procs = procs.sorted { $0.ports[0] < $1.ports[0] }
        let mem = procs.flatMap { descendants($0.pid, s) + [$0] }.reduce(0) { $0 + $1.footprint } + containers.reduce(0) { $0 + $1.mem }
        let oldest = procs.min { $0.started < $1.started }!
        let count = procs.count + containers.count

        var kinds: [(kind: String, n: Int, ports: [UInt16])] = []
        for p in procs {
            if let i = kinds.firstIndex(where: { $0.kind == serverKind(p) }) {
                kinds[i].n += 1
                kinds[i].ports += p.ports
            } else {
                kinds.append((serverKind(p), 1, p.ports))
            }
        }
        let things = kinds.map { k in "\(a(k.n, k.kind)) (\(k.ports.count == 1 ? "port" : "ports") \(list(k.ports.map(String.init))))" }
            + Dictionary(grouping: containers) { dbKind($0.image) }.sorted { $0.key < $1.key }.map { a($0.value.count, "\($0.key) database") }

        let st = starter(oldest, s)
        let age = s.now.timeIntervalSince(oldest.started)
        let work = st.claude.flatMap { claudeSession(pid: $0) }
        let job = claudeJob(dir: root)
        let jobGit = job?.jobDir.flatMap(git)
        let repo = job == nil ? git(root) : nil
        var more = procs.map { "Server: \(serverKind($0)). Command: \(commandLine($0).prefix(200))" }
            + ["Folder: \((root as NSString).abbreviatingWithTildeInPath)"]
            + containers.map { "Docker container: \($0.name) (image \($0.image))" }
        if let job {
            more.append("Claude Code background job “\(job.job ?? folder)”, state: \(job.jobState ?? "unknown")")
            if let jg = jobGit { more.append("The job worked in the git repo \(jg.repo), branch \(jg.branch). Last commit: \(jg.lastCommit)") }
        }
        more += procs.compactMap(scriptHead)

        let title: String, context: String, advice: String
        if let job {
            title = "\(procs.count == 1 ? "A test server" : "\(procs.count) test servers") from the Claude Code job “\(job.job ?? folder)” \(procs.count == 1 ? "is" : "are") still running"
            var topic = ""
            if let t = prTitle(job.prRepo, job.pr.map(String.init)) {
                topic = " The job worked on the pull request “\(t)”."
            } else if let t = job.title {
                topic = " The job worked on “\(t)”."
            } else if let jg = jobGit {
                topic = " The job worked in \(jg.repo), on the branch \(jg.branch)." + (jg.lastCommit.isEmpty ? "" : " Its last commit was “\(jg.lastCommit)”.")
            }
            let since = job.jobUpdated.map { " \(ago(s.now.timeIntervalSince($0))) ago" } ?? ""
            let working = job.jobState == "working"
            let state = working ? " The job is still working."
                : ["blocked", "failed", "error"].contains(job.jobState ?? "") ? " The job stopped\(since) because of an error, but its server still runs."
                : " The job ended\(since), but its server still runs."
            context = topic + state
            advice = working ? "" : " It is safe to stop."
        } else if let g = repo {
            title = g.isCopy ? "A copy of \(g.repo) is still running" : "\(g.repo) is still running"
            let pr = ["main", "master", "develop"].contains(g.branch) ? nil : prTitle(g.slug, g.branch)
            context = " Branch \(g.branch)." + (pr.map { " Pull request: “\($0)”." } ?? "")
                + (g.lastCommit.isEmpty ? "" : " Last commit \(g.lastCommitAgo): “\(g.lastCommit)”.")
                + " " + startedBy(st, age, work)
            advice = ["main", "master", "develop"].contains(g.branch) ? " Stop it if you are not using it." : " Stop it if you are done with this branch."
        } else {
            title = "\(folder) is still running"
            context = " " + startedBy(st, age, work)
            advice = ""
        }
        return Finding(
            id: "stack:\(root)", bucket: .leftovers, title: title,
            detail: "It runs \(list(things)).\(context) It uses \(size(mem)) in total.\(advice)",
            bytes: mem,
            actions: [Action(label: count == 1 ? "Stop it" : "Stop all \(count)",
                             fix: .all(procs.map { stop($0, termed, "").fix } + containers.map { .dockerStop($0.id) }))],
            evidence: facts(who: st.who, git: repo, work: work, more: more))
            .card(job == nil ? repo?.repo ?? folder : "a test server",
                  job.map { "From the Claude Code job “\($0.job ?? folder)”\($0.jobState == "working" ? ", which is still working" : ", which has stopped")." }
                    ?? "\(list(kinds.map { a($0.n, $0.kind) } + Dictionary(grouping: containers) { dbKind($0.image) }.sorted { $0.key < $1.key }.map { a($0.value.count, "\($0.key) database") })), on for \(ago(age)).",
                  metric: size(mem), icon: "server.rack", impact: ofRam(mem, s))
    }
}

private func projectRoot(_ dir: String) -> String {
    if isLibrary(dir) { return dir }
    var d = URL(fileURLWithPath: dir)
    while d.path.count > NSHomeDirectory().count {
        if FileManager.default.fileExists(atPath: d.appendingPathComponent(".git").path) { return d.path }
        d.deleteLastPathComponent()
    }
    return dir
}

private func serverKind(_ p: Proc) -> String {
    let a = Array(p.args.dropFirst())
    let runtime = p.name.lowercased()
    var label = String(p.name.split(separator: " ").first ?? "")
    if let i = a.firstIndex(of: "-m"), i + 1 < a.count {
        label = a[i + 1]
    } else if ["python", "python3", "node", "bun", "deno", "ruby"].contains(runtime), let script = a.first(where: { !$0.hasPrefix("-") }) {
        label = URL(fileURLWithPath: script).lastPathComponent
    }
    switch label.lowercased() {
    case "next-server", "next": return "Next.js web app"
    case "uvicorn", "gunicorn", "hypercorn", "daphne", "flask", "fastapi": return "Python API"
    case "vite": return "Vite dev server"
    case "webpack", "webpack-dev-server": return "webpack dev server"
    case "rails", "puma": return "Rails app"
    default: return runtime.hasPrefix("python") ? "Python server" : ["node", "bun", "deno"].contains(runtime) ? "Node server" : "\(label) server"
    }
}

private func commandLine(_ p: Proc) -> String {
    ([p.name] + p.args.dropFirst()).joined(separator: " ").split(whereSeparator: \.isWhitespace).joined(separator: " ")
}

private func scriptHead(_ p: Proc) -> String? {
    guard !isLibrary(p.cwd), let arg = p.args.dropFirst().first(where: { a in !a.hasPrefix("-") && [".py", ".js", ".mjs", ".ts", ".rb", ".sh"].contains(where: a.hasSuffix) }),
          !isLibrary(arg),
          let data = FileManager.default.contents(atPath: arg.hasPrefix("/") ? arg : p.cwd + "/" + arg)
    else { return nil }
    return "The file \(arg) starts with:\n" + String(decoding: data.prefix(1500), as: UTF8.self)
}

// Evidence for the AI guess. It has no sizes or ages, so it stays the same between samples and the guess cache keeps working.
private func facts(who: String?, git g: Git?, work: ClaudeWork?, more: [String]) -> String {
    var lines = more
    if let who { lines.append("Started by: \(who)") }
    if let t = work?.title { lines.append("Claude Code session title: \(t)") }
    if let g {
        let copy = g.isCopy ? " (a separate copy of the repo)" : ""
        lines.append("Git repo \(g.repo), branch \(g.branch)\(copy)." + (g.lastCommit.isEmpty ? "" : " Last commit: \(g.lastCommit)"))
    }
    return lines.joined(separator: "\n")
}

private func descendants(_ pid: pid_t, _ s: Snapshot) -> [Proc] {
    let kids = (s.children[pid] ?? []).compactMap { s.procs[$0] }
    return kids + kids.flatMap { descendants($0.pid, s) }
}

private func stop(_ p: Proc, _ termed: Set<pid_t>, _ label: String) -> Action {
    termed.contains(p.pid)
        ? Action(label: "Force quit", fix: .signal(p.pid, SIGKILL, started: p.started))
        : Action(label: label, fix: .signal(p.pid, SIGTERM, started: p.started))
}

func header(_ s: Snapshot) -> String {
    "\(size(s.ram)) memory, \(size(s.swapUsed)) moved to disk · processor \(Int((s.cpuBusy * 100).rounded()))% busy · last restart \(ago(s.uptime)) ago"
}

func text(_ s: Snapshot, _ fs: [Finding], guesses: [String: String] = [:]) -> String {
    var out = header(s) + "\n"
    for b in Bucket.allCases {
        let items = fs.filter { $0.bucket == b }
        guard !items.isEmpty else { continue }
        out += "\n\(b.rawValue)\n"
        for f in items {
            out += "  \(f.title)\n"
            if let g = f.evidence.flatMap({ guesses[$0] }) { out += "  ✨ \(g)\n" }
            out += "  \(f.detail)\n"
            if !f.steps.isEmpty { out += "  What you can do:\n" }
            for (i, step) in f.steps.enumerated() {
                out += "    \(i + 1). \(step.text)" + (step.action.map { "  [\($0.label)]  \($0.fix.command)" } ?? "") + "\n"
            }
            for a in f.actions { out += "    [\(a.label)]  \(a.fix.command)\n" }
        }
    }
    return fs.isEmpty ? out + "\nNo known cause found.\n" : out
}

func size(_ b: UInt64) -> String {
    let gb = Double(b) / Double(1 << 30)
    return gb >= 100 ? String(format: "%.0f GB", gb) : gb >= 1 ? String(format: "%.1f GB", gb) : "\(b >> 20) MB"
}

private func plural(_ n: Int, _ word: String) -> String { "\(n) \(word)\(n == 1 ? "" : word.hasSuffix("s") ? "es" : "s")" }

private func a(_ n: Int, _ word: String) -> String {
    n == 1 ? ("AEIOU".contains(word.first!) ? "an " : "a ") + word : plural(n, word)
}

private func list(_ items: [String]) -> String {
    items.count <= 2 ? items.joined(separator: " and ") : items.dropLast().joined(separator: ", ") + ", and " + items.last!
}

func ago(_ t: TimeInterval) -> String {
    switch t {
    case ..<60: return plural(Int(t), "second")
    case ..<3600: return plural(Int(t / 60), "minute")
    case ..<172_800: return plural(Int(t / 3600), "hour")
    default: return plural(Int(t / 86400), "day")
    }
}

func demoSnapshot(now: Date = Date()) -> Snapshot {
    let me = getuid()
    func p(_ pid: pid_t, _ ppid: pid_t, _ args: [String], path: String = "", age: TimeInterval = 60, cpu: Double = 0,
           mem: UInt64 = 0, ports: [UInt16] = [], cwd: String = "/tmp/wt") -> Proc {
        Proc(pid: pid, ppid: ppid, uid: me, path: path.isEmpty ? "/usr/bin/" + args[0] : path, args: args,
             started: now - age, footprint: mem, cpu: cpu, cwd: cwd, ports: ports, app: appName(path))
    }
    let proj = NSHomeDirectory() + "/whyslow-selftest/projx1"
    let sim = NSHomeDirectory() + "/Library/Developer/CoreSimulator/Devices/00000000-0000-0000-0000-000000000000/data/var/run/launchd_bootstrap.plist"
    let chrome = "/Users/x/Library/Caches/ms-playwright/chromium-1/chrome-mac-arm64/Google Chrome for Testing.app/Contents/MacOS/Google Chrome for Testing"
    let procs = [
        p(10, 1, ["login"]), p(11, 10, ["-zsh"]), p(12, 11, ["claude"]),
        p(13, 12, ["zsh", "-c", "make test-cov"]), p(14, 13, ["make", "test-cov"], age: 43),
        p(15, 14, ["python", "-m", "pytest"], cpu: 0.9), p(16, 15, ["python"], cpu: 0.9), p(17, 15, ["python"], cpu: 0.9),
        p(20, 1, [chrome], path: chrome, age: 6 * 86400, mem: 300 << 20), p(21, 20, ["helper"], mem: 30 << 20),
        p(22, 11, [chrome], path: chrome, age: 6 * 86400),
        p(23, 1, ["crashpad"], path: chrome.replacingOccurrences(of: "MacOS/", with: "Frameworks/"), age: 6 * 86400),
        p(30, 11, ["caffeinate", "-dimsu"], age: 7200), p(31, 12, ["caffeinate", "-i", "-t", "300"], age: 7200),
        p(32, 11, ["caffeinate", "-i", "make"], age: 7200), p(33, 11, ["caffeinate", "-i"], age: 60),
        p(40, 1, ["Python", "-m", "uvicorn", "app:app"], age: 13 * 3600, mem: 50 << 20, ports: [8000], cwd: proj),
        p(41, 11, ["node", "server.mjs"], age: 13 * 3600, mem: 20 << 20, ports: [3000], cwd: proj),
        p(42, 40, ["Python", "-m", "uvicorn"], age: 13 * 3600, ports: [8000], cwd: proj),
        p(43, 11, ["node", "fresh.mjs"], age: 60, ports: [5173], cwd: proj),
        p(44, 1, ["helper", "serve.js"], age: 13 * 3600, ports: [9999], cwd: NSHomeDirectory() + "/Library/Containers/com.example/Data"),
        p(50, 1, ["launchd_sim", sim], age: 5 * 86400, mem: 10 << 20), p(51, 50, ["SpringBoard"], mem: 200 << 20),
        p(60, 1, ["Google Chrome"], path: "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome", mem: 1 << 30),
        p(61, 60, ["renderer"], path: "/Applications/Google Chrome.app/Contents/Frameworks/Google Chrome Framework.framework/Helpers/Google Chrome Helper (Renderer).app/Contents/MacOS/Google Chrome Helper (Renderer)", mem: 1 << 30),
        p(62, 1, ["Safari"], path: "/Applications/Safari.app/Contents/MacOS/Safari", mem: 200 << 20),
        p(63, 1, ["webcontent"], path: "/System/Library/Frameworks/WebKit.framework/Versions/A/XPCServices/com.apple.WebKit.WebContent.xpc/Contents/MacOS/com.apple.WebKit.WebContent", cpu: 1.2, mem: 300 << 20),
        p(64, 1, ["photoanalysisd"], path: "/System/Library/PrivateFrameworks/PhotoAnalysis.framework/Versions/A/Support/photoanalysisd", cpu: 1.2),
        p(80, 1, ["com.docker.backend"], path: "/Applications/Docker.app/Contents/MacOS/com.docker.backend"),
        p(81, 1, ["vm"], path: "/System/Library/Frameworks/Virtualization.framework/Versions/A/XPCServices/com.apple.Virtualization.VirtualMachine.xpc/Contents/MacOS/com.apple.Virtualization.VirtualMachine", cpu: 1.2, mem: 2 << 30),
        p(70, 1, ["loginwindow"], path: "/System/Library/CoreServices/loginwindow.app/Contents/MacOS/loginwindow", age: 10 * 86400),
    ]
    let atLogin = 10 * 86400.0 - 60
    let login: [(pid: pid_t, name: String, id: String, bundle: String, background: Bool, age: TimeInterval, mb: UInt64)] = [
        (71, "Dropbox", "com.getdropbox.dropbox", "/Applications/Dropbox.app", true, atLogin, 700),
        (72, "Zoom", "us.zoom.xos", "/Applications/zoom.us.app", false, atLogin, 600),
        (73, "Logi Options+", "com.logi.optionsplus", "/Applications/logioptionsplus.app", true, 2 * 86400, 500),
        (74, "Spotify", "com.spotify.client", "/Applications/Spotify.app", false, atLogin, 400),
        (75, "Slack", "com.tinyspeck.slackmacgap", "/Applications/Slack.app", false, 86400, 900),
        (76, "1Password Browser Helper", "com.1password.browser-helper", "/Applications/1Password.app/Contents/Library/LoginItems/1Password Browser Helper.app", true, 3 * 86400, 300),
        (77, "Raycast", "com.raycast.macos", "/Applications/Raycast.app", true, 3 * 86400, 200),
        (78, "Rectangle", "com.knollsoft.Rectangle", "/Applications/Rectangle.app", true, 3 * 86400, 100),
        (79, "Music", "com.apple.Music", "/System/Applications/Music.app", false, atLogin, 800),
    ]
    let loginProcs = login.map { p($0.pid, 1, [$0.name], path: "\($0.bundle)/Contents/MacOS/\($0.name)", age: $0.age, mem: $0.mb << 20) }
    let apps = login.map { RunningApp(pid: $0.pid, name: $0.name, bundleID: $0.id, path: $0.bundle, background: $0.background) }
        + [RunningApp(pid: 60, name: "Google Chrome", bundleID: "com.google.Chrome", path: "/Applications/Google Chrome.app", background: false),
           RunningApp(pid: 62, name: "Safari", bundleID: "com.apple.Safari", path: "/Applications/Safari.app", background: false)]
    let containers = [Container(id: "c1", name: "projx1-db", status: "Up 13 hours", image: "postgres:17", mem: 100 << 20),
                      Container(id: "c2", name: "other-db", status: "Up 2 days", image: "redis", mem: 1 << 20)]
    var s = Snapshot(procs: Dictionary(uniqueKeysWithValues: (procs + loginProcs).map { ($0.pid, $0) }), containers: containers, apps: apps,
                     diskFree: 9 << 30, diskTotal: 256 << 30, ram: 8 << 30, cores: 10, now: now, thermal: .serious)
    s.access["com.google.Chrome"] = .notAsked
    s.index()
    return s
}

func selfTest() {
    let now = Date()
    let snap = demoSnapshot(now: now)
    let fs = findings(snap)
    func one(_ id: String) -> Finding {
        let f = fs.filter { $0.id == id }
        precondition(f.count == 1, "expected one \(id): \(fs.map(\.id))")
        return f[0]
    }

    precondition(one("heat").title == "Your Mac is hot, so macOS slows it down" && fs.first?.id == "heat")
    precondition(verdict(snap, fs) == ("Your Mac is too hot.", nil, false))
    var calm = snap
    (calm.thermal, calm.diskFree, calm.pressure) = (.nominal, 100 << 30, 2)
    precondition(verdict(calm, findings(calm)) == ("Your Mac is short on memory.", "The biggest cause: Apps that start at login.", false), "\(verdict(calm, findings(calm)))")
    precondition(verdict(Snapshot(procs: [:]), []) == ("Your Mac looks fine right now.", nil, true))
    precondition(one("browser-app:Google Chrome").summary == "Each open tab uses memory. whyslow can find the tabs that you can close.")
    var cool = snap
    cool.thermal = .fair
    precondition(!findings(cool).contains { $0.id == "heat" })
    let chrome = one("browser-app:Google Chrome")
    precondition(chrome.title == "Chrome uses 2.0 GB of memory" && chrome.bucket == .always, chrome.title)
    precondition(chrome.detail.hasPrefix("That is 25% of your Mac's memory.") && chrome.detail.contains("Chrome runs 2 processes"), chrome.detail)
    precondition(chrome.actions.isEmpty && chrome.steps.compactMap(\.action?.label) == ["See my open tabs", "Quit Chrome"], "\(chrome.steps)")
    var allowed = snap
    allowed.access["com.google.Chrome"] = .allowed
    allowed.tabs["com.google.Chrome"] = Tabs(duplicates: 5, piles: [("github.com", 9), ("calendar.google.com", 5), ("claude.ai", 4)])
    let withTabs = findings(allowed).first { $0.id == "browser-app:Google Chrome" }!
    precondition(withTabs.steps.map(\.text) == [
        "5 tabs show the same page as another tab.",
        "Many tabs are from the same site: 9 from GitHub, 5 from Google Calendar, and 4 from Claude. Close the ones that you are done with.",
        "Turn on Memory Saver, if it is off. Chrome then puts tabs that you have not used for a while to sleep.",
        "Quit and open Chrome again. This frees memory that Chrome holds on to over time.",
    ], "\(withTabs.steps.map(\.text))")
    precondition(withTabs.steps.map { $0.action?.fix.command ?? "-" } == [
        "close the duplicate tabs in com.google.Chrome, keep the first copy", "-",
        "open chrome://settings/performance in com.google.Chrome", "Cmd-Q com.google.Chrome",
    ])
    allowed.memorySaver = 2
    precondition(!findings(allowed).first { $0.id == "browser-app:Google Chrome" }!.steps.contains { $0.text.contains("Memory Saver") })
    allowed.memorySaver = 0
    precondition(findings(allowed).first { $0.id == "browser-app:Google Chrome" }!.steps.contains { $0.text.hasPrefix("Turn on Memory Saver. Chrome") })
    var denied = snap
    denied.access["com.google.Chrome"] = .denied
    precondition(findings(denied).first { $0.id == "browser-app:Google Chrome" }!.steps.first?.action?.fix.command
                 == "open x-apple.systempreferences:com.apple.preference.security?Privacy_Automation")
    precondition(one("browser-app:Safari").steps.map(\.text).first == "Close the tabs that you do not need.")
    let safari = one("browser-app:Safari")
    precondition(safari.title == "Safari is working hard" && safari.metric == "12% CPU" && safari.bucket == .now && safari.detail.contains("Safari runs 2 processes"), safari.title)
    let photos = one("service:Photos is analyzing your pictures")
    precondition(photos.title == "Photos is analyzing your pictures" && photos.metric == "12% CPU" && photos.actions.isEmpty, photos.title)
    let disk = one("disk")
    precondition(disk.detail.hasPrefix("Only 9.0 GB of 256 GB is free.") && disk.actions.map(\.fix.command) == ["open x-apple.systempreferences:com.apple.settings.Storage"], disk.detail)
    let login = one("login")
    precondition(login.title == "7 apps start by themselves", login.title)
    precondition(login.detail.hasPrefix("Dropbox, Zoom, Logi Options+, Spotify, and 3 more open when you log in"), login.detail)
    precondition(login.actions.map(\.fix.command) == ["open x-apple.systempreferences:com.apple.LoginItems-Settings.extension"])

    let stack = fs.filter { $0.id.hasPrefix("stack") }
    precondition(stack.count == 1 && stack[0].title == "projx1 is still running", "\(stack)")
    precondition(stack[0].detail.hasPrefix("It runs a Node server (port 3000), a Python API (port 8000), and a Postgres database."), stack[0].detail)
    precondition(stack[0].detail.contains("You started it in a terminal 13 hours ago.") && stack[0].bytes == 170 << 20, stack[0].detail)
    precondition(stack[0].actions[0].label == "Stop all 3" && stack[0].actions[0].fix.command == "kill -TERM 41; kill -TERM 40; docker stop c1")
    precondition(stack[0].actions[0].fix.pids == [41, 40])
    precondition(stack[0].evidence?.hasPrefix("Server: Node server. Command: node server.mjs\nServer: Python API.") == true, stack[0].evidence ?? "")
    precondition(stack[0].evidence?.contains("Docker container: projx1-db (image postgres:17)") == true && !(stack[0].evidence ?? "").contains("hours"))
    let sims = fs.filter { $0.id == "simulators" }
    precondition(sims.count == 1 && sims[0].title == "1 Xcode simulator uses 210 MB", "\(sims)")
    precondition(sims[0].actions[0].fix.command == "simctl shutdown 00000000-0000-0000-0000-000000000000")

    precondition(one("docker").summary.hasSuffix("It also uses 12% CPU now.") && one("docker").detail.contains("Docker also uses 12% CPU right now"), one("docker").summary)
    let cpu = fs.filter { $0.id.hasPrefix("cpu:") }
    precondition(cpu.count == 1 && cpu[0].title == "Claude Code is running tests" && cpu[0].metric == "27% CPU", "\(cpu)")
    precondition(cpu[0].detail.hasPrefix("Claude Code started it 43 seconds ago."), cpu[0].detail)
    let browsers = fs.filter { $0.id.hasPrefix("browser:") }
    precondition(browsers.count == 1 && browsers[0].bytes == 330 << 20, "\(browsers)")
    precondition(browsers[0].actions.first?.fix.command == "kill -TERM 20")
    precondition(findings(snap, termed: [20]).first { $0.id == "browser:20" }?.actions.first?.fix.command == "kill -KILL 20")
    precondition(fs.filter { $0.id.hasPrefix("caffeinate") }.map(\.id) == ["caffeinate:30"])
    precondition(list(["a", "b", "c"]) == "a, b, and c" && ago(1) == "1 second" && onFor("Up 3 hours (healthy)") == "on for 3 hours")

    precondition(Fix.signal(1, SIGTERM, started: now).apply()?.hasPrefix("Not done") == true)
    let sleeper = Process()
    sleeper.executableURL = URL(fileURLWithPath: "/bin/sleep")
    sleeper.arguments = ["30"]
    try! sleeper.run()
    let started = Date(timeIntervalSince1970: Double(bsdInfo(sleeper.processIdentifier)!.pbi_start_tvsec))
    precondition(Fix.signal(sleeper.processIdentifier, SIGTERM, started: started - 5).apply()?.hasPrefix("Not done") == true)
    precondition(Fix.signal(sleeper.processIdentifier, SIGTERM, started: started).apply() == nil)
    sleeper.waitUntilExit()
    precondition(sleeper.terminationReason == .uncaughtSignal && sleeper.terminationStatus == SIGTERM)
    print("selftest ok")
}
