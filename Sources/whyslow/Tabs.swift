import AppKit
import CoreServices

enum Access { case allowed, denied, notAsked, unknown }

struct Tabs {
    var duplicates: Int
    var piles: [(host: String, n: Int)]
}

let scriptableBrowsers: Set = ["com.apple.Safari", "com.google.Chrome", "company.thebrowser.Browser",
                               "com.microsoft.edgemac", "com.brave.Browser", "com.vivaldi.Vivaldi"]

// With ask == true, macOS shows its Automation prompt and this call blocks until the user answers, so never call it on the main thread.
func automation(_ bundleID: String, ask: Bool) -> Access {
    switch AEDeterminePermissionToAutomateTarget(NSAppleEventDescriptor(bundleIdentifier: bundleID).aeDesc, typeWildCard, typeWildCard, ask) {
    case noErr: return .allowed
    case OSStatus(errAEEventNotPermitted): return .denied
    case OSStatus(errAEEventWouldRequireUserConsent): return .notAsked
    default: return .unknown
    }
}

// NSAppleScript is main-thread only.
private func appleScript(_ source: String) -> NSAppleEventDescriptor? {
    let run = { () -> NSAppleEventDescriptor? in
        var err: NSDictionary?
        let result = NSAppleScript(source: source)?.executeAndReturnError(&err)
        return err == nil ? result : nil
    }
    return Thread.isMainThread ? run() : DispatchQueue.main.sync(execute: run)
}

func readTabs(_ bundleID: String) -> Tabs? {
    guard let windows = appleScript("tell application id \"\(bundleID)\" to get URL of every tab of every window"), windows.numberOfItems > 0 else { return nil }
    var urls: [String] = []
    for w in 1...windows.numberOfItems {
        guard let tabs = windows.atIndex(w), tabs.numberOfItems > 0 else { continue }
        for t in 1...tabs.numberOfItems { urls.append(tabs.atIndex(t)?.stringValue ?? "") }
    }
    let hosts = urls.compactMap { URL(string: $0)?.host() }.map { $0.hasPrefix("www.") ? String($0.dropFirst(4)) : $0 }
    let piles = Dictionary(grouping: hosts, by: { $0 }).map { (host: $0.key, n: $0.value.count) }
        .filter { $0.n >= 3 }.sorted { ($0.n, $1.host) > ($1.n, $0.host) }.prefix(3)
    return Tabs(duplicates: urls.count - Set(urls).count, piles: Array(piles))
}

// Works out the duplicates again at click time, so tabs opened or closed since the last sample are handled. Keeps the first copy, front window first.
func closeDuplicates(in bundleID: String) -> Bool {
    appleScript("""
        tell application id "\(bundleID)"
            set seen to {}
            repeat with w in windows
                try
                    set extra to {}
                    repeat with i from 1 to (count of tabs of w)
                        set u to URL of tab i of w
                        if seen contains {u} then
                            set end of extra to i
                        else
                            set end of seen to u
                        end if
                    end repeat
                    repeat with k from (count of extra) to 1 by -1
                        close tab (item k of extra) of w
                    end repeat
                end try
            end repeat
        end tell
        """) != nil
}

func openPage(_ url: String, in bundleID: String) -> Bool {
    appleScript("""
        tell application id "\(bundleID)"
            activate
            make new tab at end of tabs of front window with properties {URL:"\(url)"}
        end tell
        """) != nil
}
