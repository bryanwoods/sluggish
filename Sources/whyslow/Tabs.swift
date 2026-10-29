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

// Runs in /usr/bin/osascript, not NSAppleScript: loading the AppleScript engine into whyslow costs about 15 MB
// for the life of the app. macOS still applies whyslow's Automation permission, because whyslow starts the child.
private func appleScript(_ source: String) -> String? {
    guard let h = start("/usr/bin/osascript", ["-e", source]) else { return nil }
    let out = finish(h)
    return h.0.terminationStatus == 0 ? out : nil
}

func readTabs(_ bundleID: String) -> Tabs? {
    guard let out = appleScript("""
        set text item delimiters to linefeed
        tell application id "\(bundleID)" to set urls to URL of every tab of every window
        return urls as text
        """) else { return nil }
    let urls = out.split(separator: "\n").map(String.init)
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
