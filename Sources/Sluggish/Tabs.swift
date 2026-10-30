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

// Runs in /usr/bin/osascript, not NSAppleScript: loading the AppleScript engine into Sluggish costs about 15 MB
// for the life of the app. macOS still applies Sluggish's Automation permission, because Sluggish starts the child.
private func appleScript(_ source: String) -> String? {
    guard let h = start("/usr/bin/osascript", ["-e", source]) else { return nil }
    let out = finish(h)
    return h.0.terminationStatus == 0 ? out : nil
}

// Scripting codes from each app's dictionary (sdef). Chromium browsers share Chrome's.
// ponytail: the Brave, Edge, and Vivaldi codes are assumed from Chromium, not checked; other browsers use osascript.
private let tabCodes = ["com.apple.Safari": ("bTab", "pURL"), "com.google.Chrome": ("CrTb", "URL "), "com.brave.Browser": ("CrTb", "URL "),
                        "com.microsoft.edgemac": ("CrTb", "URL "), "com.vivaldi.Vivaldi": ("CrTb", "URL ")]

private func code(_ s: String) -> FourCharCode { s.utf8.reduce(0) { $0 << 8 | FourCharCode($1) } }

// An object specifier: "every <class> of <container>", or "<property> of <container>".
private func specifier(_ want: String, form: String, data: NSAppleEventDescriptor, of container: NSAppleEventDescriptor) -> NSAppleEventDescriptor {
    let spec = NSAppleEventDescriptor.record()
    spec.setDescriptor(NSAppleEventDescriptor(typeCode: code(want)), forKeyword: code("want"))
    spec.setDescriptor(NSAppleEventDescriptor(enumCode: code(form)), forKeyword: code("form"))
    spec.setDescriptor(data, forKeyword: code("seld"))
    spec.setDescriptor(container, forKeyword: code("from"))
    return spec.coerce(toDescriptorType: code("obj "))!
}

// Sends the Apple Event for "URL of every tab of every window" directly. This needs no AppleScript engine and no child process.
private func tabURLs(_ bundleID: String) -> [String]? {
    guard let (tab, url) = tabCodes[bundleID] else { return nil }
    var all = code("all ")
    let every = NSAppleEventDescriptor(descriptorType: code("abso"), bytes: &all, length: 4)!
    let windows = specifier("cwin", form: "indx", data: every, of: .null())
    let tabs = specifier(tab, form: "indx", data: every, of: windows)
    let urls = specifier("prop", form: "prop", data: NSAppleEventDescriptor(typeCode: code(url)), of: tabs)
    let event = NSAppleEventDescriptor.appleEvent(withEventClass: code("core"), eventID: code("getd"),
                                                  targetDescriptor: NSAppleEventDescriptor(bundleIdentifier: bundleID),
                                                  returnID: AEReturnID(kAutoGenerateReturnID), transactionID: AETransactionID(kAnyTransactionID))
    event.setParam(urls, forKeyword: code("----"))
    guard let reply = try? event.sendEvent(options: [.waitForReply, .neverInteract], timeout: 3),
          let byWindow = reply.paramDescriptor(forKeyword: code("----")) else { return nil }
    return (0..<byWindow.numberOfItems).flatMap { w in
        let list = byWindow.atIndex(w + 1)
        return (0..<(list?.numberOfItems ?? 0)).map { list?.atIndex($0 + 1)?.stringValue ?? "" }
    }
}

func readTabs(_ bundleID: String) -> Tabs? {
    guard let urls = tabURLs(bundleID) ?? appleScript("""
        set text item delimiters to linefeed
        tell application id "\(bundleID)" to set urls to URL of every tab of every window
        return urls as text
        """)?.split(separator: "\n").map(String.init) else { return nil }
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
