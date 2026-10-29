import Foundation

struct Git {
    var repo, branch, lastCommit, lastCommitAgo: String
    var isCopy: Bool
    var slug: String?
}

// /usr/bin/git and /usr/bin/xcrun are stubs that show an install dialog when the developer tools are missing, so only real binaries are used.
private let developerDir = (try? FileManager.default.destinationOfSymbolicLink(atPath: "/var/db/xcode_select_link")) ?? "/Library/Developer/CommandLineTools"
// WHYSLOW_NO_TOOLS=1 hides every optional tool, to check that the cards still read well without them.
func executable(_ paths: [String]) -> String? {
    ProcessInfo.processInfo.environment["WHYSLOW_NO_TOOLS"] == nil ? paths.first { FileManager.default.isExecutableFile(atPath: $0) } : nil
}
let gitBin = executable(["/opt/homebrew/bin/git", "/usr/local/bin/git", developerDir + "/usr/bin/git", "/Library/Developer/CommandLineTools/usr/bin/git"])
let simctlBin = executable([developerDir + "/usr/bin/simctl"])
let ghBin = executable([NSHomeDirectory() + "/bin/gh", "/opt/homebrew/bin/gh", "/usr/local/bin/gh"])
var prLookups: Bool { UserDefaults.standard.bool(forKey: "prTitles") || CommandLine.arguments.contains("--pr") }
// ponytail: process-lifetime cache, never expires; one gh call (~0.6 s) per new PR on the first sample
private var prCache: [String: String?] = [:]

func prTitle(_ slug: String?, _ ref: String?) -> String? {
    guard prLookups, let slug, let ref, let gh = ghBin else { return nil }
    let key = "\(slug)#\(ref)"
    if let hit = prCache[key] { return hit }
    let title = finish(start(gh, ["pr", "view", ref, "--repo", slug, "--json", "title", "--jq", ".title"])).trimmingCharacters(in: .whitespacesAndNewlines)
    prCache[key] = title.isEmpty ? nil : title
    return prCache[key]!
}

// Branch and remote come from the files in .git; a worktree's .git is a file that points to its gitdir, and commondir points to the main repo.
func git(_ root: String) -> Git? {
    func read(_ path: String) -> String? { (try? String(contentsOfFile: path, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines) }
    func resolve(_ path: String, _ base: String) -> String { path.hasPrefix("/") ? path : URL(fileURLWithPath: base).appendingPathComponent(path).standardized.path }
    var isDir: ObjCBool = false
    guard FileManager.default.fileExists(atPath: root + "/.git", isDirectory: &isDir) else { return nil }
    var gitDir = root + "/.git"
    if !isDir.boolValue {
        guard let link = read(gitDir), link.hasPrefix("gitdir: ") else { return nil }
        gitDir = resolve(String(link.dropFirst(8)), root)
    }
    guard let head = read(gitDir + "/HEAD") else { return nil }
    let branch = head.hasPrefix("ref: refs/heads/") ? String(head.dropFirst(16)) : String(head.prefix(7))
    let config = read(resolve(read(gitDir + "/commondir") ?? ".", gitDir) + "/config") ?? ""
    var inOrigin = false, url = ""
    for line in config.split(separator: "\n").map({ $0.trimmingCharacters(in: .whitespaces) }) {
        if line.hasPrefix("[") { inOrigin = line == "[remote \"origin\"]" }
        else if inOrigin, line.hasPrefix("url") { url = line.split(separator: "=", maxSplits: 1).last.map { $0.trimmingCharacters(in: .whitespaces) } ?? "" }
    }
    let parts = url.split(whereSeparator: { $0 == "/" || $0 == ":" }).map(String.init)
    var repo = parts.last ?? ""
    if repo.hasSuffix(".git") { repo.removeLast(4) }
    let last = gitBin.map { finish(start($0, ["-C", root, "log", "-1", "--format=%cr%n%s"])) }?
        .trimmingCharacters(in: .whitespacesAndNewlines).split(separator: "\n", maxSplits: 1).map(String.init) ?? []
    return Git(repo: repo.isEmpty ? URL(fileURLWithPath: root).lastPathComponent : repo, branch: branch,
               lastCommit: last.count == 2 ? last[1] : "", lastCommitAgo: last.first ?? "", isCopy: !isDir.boolValue,
               slug: url.contains("github.com") && parts.count >= 2 ? "\(parts[parts.count - 2])/\(repo)" : nil)
}

struct ClaudeWork {
    var title: String?
    var pr: Int?
    var prRepo: String?
    var job: String?
    var jobState: String?
    var jobUpdated: Date?
    var jobDir: String?
}

// sessions/<pid>.json, jobs/<id>/state.json and the transcripts are Claude Code's internal files: every field is optional.
func claudeSession(pid: pid_t) -> ClaudeWork? {
    guard let s = json(NSHomeDirectory() + "/.claude/sessions/\(pid).json"), let id = s["sessionId"] as? String else { return nil }
    return transcript(id)
}

func claudeJob(dir: String) -> ClaudeWork? {
    let jobs = NSHomeDirectory() + "/.claude/jobs/"
    guard dir.hasPrefix(jobs), let id = dir.dropFirst(jobs.count).split(separator: "/").first,
          let s = json(jobs + id + "/state.json") else { return nil }
    var w = (s["sessionId"] as? String).map(transcript) ?? ClaudeWork()
    w.job = s["name"] as? String ?? String(id)
    w.jobState = s["state"] as? String
    w.jobDir = s["cwd"] as? String
    let iso = ISO8601DateFormatter()
    iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    w.jobUpdated = (s["updatedAt"] as? String).flatMap(iso.date)
    return w
}

private func transcript(_ sessionId: String) -> ClaudeWork {
    let projects = NSHomeDirectory() + "/.claude/projects"
    var w = ClaudeWork()
    guard let path = ((try? FileManager.default.contentsOfDirectory(atPath: projects)) ?? [])
            .map({ "\(projects)/\($0)/\(sessionId).jsonl" }).first(where: FileManager.default.fileExists),
          let fh = FileHandle(forReadingAtPath: path)
    else { return w }
    defer { try? fh.close() }
    // ponytail: reads the last 1 MB only; a session whose title is older than that shows no title
    let end = (try? fh.seekToEnd()) ?? 0
    try? fh.seek(toOffset: end > 1 << 20 ? end - (1 << 20) : 0)
    for line in String(decoding: fh.readDataToEndOfFile(), as: UTF8.self).split(separator: "\n")
    where line.contains("\"ai-title\"") || line.contains("\"pr-link\"") {
        guard let d = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] else { continue }
        if let t = d["aiTitle"] as? String { w.title = t }
        if let n = d["prNumber"] as? Int {
            w.pr = n
            w.prRepo = d["prRepository"] as? String
        }
    }
    return w
}

private func json(_ path: String) -> [String: Any]? {
    FileManager.default.contents(atPath: path).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
}
