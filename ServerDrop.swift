// ServerDrop: a Dock tile that sends dropped files to a server over Taildrop,
// and a window listing transfers both ways.
//
// Sending happens here. Receiving is done by recv.sh under launchd, so files
// land while this app is closed; both append to the same history.jsonl.

import AppKit
import SwiftUI

let support = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent("Library/Application Support/ServerDrop")
let logURL = support.appendingPathComponent("history.jsonl")

// install.sh writes SERVER=<tailscale machine name> into the config file.
let server: String = {
    let text = (try? String(contentsOf: support.appendingPathComponent("config"), encoding: .utf8)) ?? ""
    let line = text.split(separator: "\n").first { $0.hasPrefix("SERVER=") }
    return line.map { String($0.dropFirst(7)) } ?? "server"
}()

// One line of history.jsonl. A send writes "sending" and then "done" or
// "failed" under the same id; the latest line per id wins.
struct Event: Codable, Identifiable {
    var id: String
    var at: Double
    var dir: String          // "out" = Mac -> server, "in" = server -> Mac
    var name: String
    var path: String?
    var status: String       // sending | done | failed
    var detail: String?
}

func run(_ exe: String, _ args: [String]) -> (Int32, String) {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: exe)
    p.arguments = args
    let pipe = Pipe()
    p.standardOutput = pipe
    p.standardError = pipe
    do { try p.run() } catch { return (-1, error.localizedDescription) }
    let out = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    p.waitUntilExit()
    return (p.terminationStatus, out.trimmingCharacters(in: .whitespacesAndNewlines))
}

final class History: ObservableObject {
    static let shared = History()
    @Published var items: [Event] = []

    init() {
        reload()
        Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in self?.reload() }
    }

    func append(_ e: Event) {
        try? FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        guard var line = try? JSONEncoder().encode(e) else { return }
        line.append(0x0A)
        if let fh = try? FileHandle(forWritingTo: logURL) {
            fh.seekToEndOfFile()
            fh.write(line)
            try? fh.close()
        } else {
            try? line.write(to: logURL)
        }
        reload()
    }

    func reload() {
        let lines = ((try? String(contentsOf: logURL, encoding: .utf8)) ?? "").split(separator: "\n")
        var latest: [String: Event] = [:]
        var order: [String] = []
        for line in lines {
            guard var e = try? JSONDecoder().decode(Event.self, from: Data(line.utf8)) else { continue }
            if let first = latest[e.id] {
                e.at = first.at
                e.path = e.path ?? first.path
            } else {
                order.append(e.id)
            }
            latest[e.id] = e
        }
        items = order.reversed().prefix(200).compactMap { latest[$0] }
    }
}

// One tailscale process per file, so each row gets its own status.
// Taildrop only carries files, so a folder goes as Folder.zip.
func send(_ url: URL) {
    var isDir: ObjCBool = false
    guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) else { return }
    let id = UUID().uuidString
    let name = url.lastPathComponent + (isDir.boolValue ? ".zip" : "")
    let started = Date().timeIntervalSince1970
    History.shared.append(Event(id: id, at: started, dir: "out", name: name, path: url.path, status: "sending"))

    DispatchQueue.global().async {
        var file = url
        var result: (Int32, String) = (0, "")
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(id)
        if isDir.boolValue {
            try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
            file = tmp.appendingPathComponent(name)
            result = run("/usr/bin/ditto", ["-c", "-k", "--keepParent", url.path, file.path])
        }
        if result.0 == 0 {
            result = run("/usr/local/bin/tailscale", ["file", "cp", file.path, "\(server):"])
        }
        try? FileManager.default.removeItem(at: tmp)
        DispatchQueue.main.async {
            History.shared.append(Event(id: id, at: started, dir: "out", name: name,
                                        status: result.0 == 0 ? "done" : "failed",
                                        detail: result.1.split(separator: "\n").last.map(String.init)))
        }
    }
}

struct ContentView: View {
    @ObservedObject var history = History.shared
    @State private var targeted = false

    var body: some View {
        VStack(spacing: 0) {
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(targeted ? Color.accentColor : .secondary,
                              style: StrokeStyle(lineWidth: 2, dash: [7, 5]))
                .frame(height: 90)
                .overlay(Text("Drop files to send to \(server)").font(.headline))
                .padding(14)
                .onDrop(of: [.fileURL], isTargeted: $targeted) { providers in
                    for p in providers {
                        _ = p.loadObject(ofClass: URL.self) { url, _ in
                            if let url { DispatchQueue.main.async { send(url) } }
                        }
                    }
                    return true
                }
            List(history.items) { e in
                HStack {
                    Image(systemName: e.dir == "out" ? "arrow.up.circle.fill" : "arrow.down.circle.fill")
                        .foregroundStyle(e.dir == "out" ? .blue : .green)
                    Text(e.name).lineLimit(1).truncationMode(.middle)
                    Spacer()
                    switch e.status {
                    case "sending": ProgressView().controlSize(.small)
                    case "failed": Image(systemName: "xmark.octagon.fill").foregroundStyle(.red).help(e.detail ?? "")
                    default: Text(Date(timeIntervalSince1970: e.at), style: .relative).foregroundStyle(.secondary)
                    }
                }
                .contentShape(Rectangle())
                .onTapGesture(count: 2) {
                    if let p = e.path { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: p)]) }
                }
            }
        }
        .frame(minWidth: 360, minHeight: 400)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 480),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable],
                          backing: .buffered, defer: false)

    func applicationDidFinishLaunching(_ note: Notification) {
        window.title = "ServerDrop"
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: ContentView())
        window.center()
        show()
    }

    // Files dropped on the Dock tile arrive here.
    func application(_ sender: NSApplication, open urls: [URL]) {
        urls.forEach(send)
        show()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        show()
        return true
    }

    func show() {
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

let delegate = AppDelegate()
NSApplication.shared.delegate = delegate
NSApplication.shared.setActivationPolicy(.regular)
NSApplication.shared.run()
