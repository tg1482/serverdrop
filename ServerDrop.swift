// ServerDrop: a Dock tile that sends dropped files to the dev box over
// Taildrop, and a window listing every transfer in both directions.
//
// Sending happens here. Receiving is done by recv.sh under launchd, so files
// from the server still land while this app is closed; both write the same
// JSONL history, which the window re-reads whenever it changes.

import AppKit
import SwiftUI
import UniformTypeIdentifiers
import UserNotifications

let tailscale = "/usr/local/bin/tailscale"
let receiverLabel = "io.github.tg1482.serverdrop.recv"
let supportDir = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent("Library/Application Support/ServerDrop")
let logURL = supportDir.appendingPathComponent("history.jsonl")

// install.sh writes SERVER=<tailscale machine name> into this file.
let peer: String = {
    let text = (try? String(contentsOf: supportDir.appendingPathComponent("config"), encoding: .utf8)) ?? ""
    for line in text.split(separator: "\n") where line.hasPrefix("SERVER=") {
        return String(line.dropFirst("SERVER=".count)).trimmingCharacters(in: .whitespaces)
    }
    return "server"
}()

// One line of history.jsonl. A send writes "sending" then "done"/"failed"
// under the same id; the reader keeps the latest status per id.
struct Event: Codable {
    var id: String
    var at: Double
    var dir: String          // "out" = Mac -> server, "in" = server -> Mac
    var name: String
    var bytes: Int64?
    var path: String?
    var status: String       // sending | done | failed
    var detail: String?
}

struct Transfer: Identifiable {
    let id: String
    var at: Date
    var dir: String
    var name: String
    var bytes: Int64?
    var path: String?
    var status: String
    var detail: String?
}

@discardableResult
func run(_ exe: String, _ args: [String]) -> (Int32, String) {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: exe)
    p.arguments = args
    let pipe = Pipe()
    p.standardOutput = pipe
    p.standardError = pipe
    do { try p.run() } catch { return (-1, error.localizedDescription) }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    return (p.terminationStatus, String(decoding: data, as: UTF8.self)
        .trimmingCharacters(in: .whitespacesAndNewlines))
}

func reveal(_ path: String?) {
    guard let path, FileManager.default.fileExists(atPath: path) else { return }
    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
}

final class History: ObservableObject {
    static let shared = History()
    @Published var items: [Transfer] = []
    @Published var receiverUp = false
    @Published var sending = 0 {
        didSet { NSApp.dockTile.badgeLabel = sending > 0 ? "\(sending)" : nil }
    }
    private var stamp: (Date?, Int)?
    private var ticks = 0

    init() {
        reload()
        checkReceiver()
        Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.reloadIfChanged()
            self.ticks += 1
            if self.ticks % 5 == 0 { self.checkReceiver() }
        }
    }

    func append(_ e: Event) {
        try? FileManager.default.createDirectory(at: supportDir, withIntermediateDirectories: true)
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

    private func reloadIfChanged() {
        let attrs = try? FileManager.default.attributesOfItem(atPath: logURL.path)
        let now = (attrs?[.modificationDate] as? Date, (attrs?[.size] as? Int) ?? -1)
        if stamp.map({ $0.0 != now.0 || $0.1 != now.1 }) ?? true { reload() }
    }

    func reload() {
        let attrs = try? FileManager.default.attributesOfItem(atPath: logURL.path)
        stamp = (attrs?[.modificationDate] as? Date, (attrs?[.size] as? Int) ?? -1)
        guard let text = try? String(contentsOf: logURL, encoding: .utf8) else { items = []; return }
        var byId: [String: Transfer] = [:]
        var order: [String] = []
        let decoder = JSONDecoder()
        for line in text.split(separator: "\n") {
            guard let e = try? decoder.decode(Event.self, from: Data(line.utf8)) else { continue }
            if var t = byId[e.id] {
                t.status = e.status
                t.detail = e.detail ?? t.detail
                t.bytes = e.bytes ?? t.bytes
                t.path = e.path ?? t.path
                byId[e.id] = t
            } else {
                order.append(e.id)
                byId[e.id] = Transfer(id: e.id, at: Date(timeIntervalSince1970: e.at), dir: e.dir,
                                      name: e.name, bytes: e.bytes, path: e.path,
                                      status: e.status, detail: e.detail)
            }
        }
        items = order.reversed().prefix(200).compactMap { byId[$0] }
    }

    private func checkReceiver() {
        DispatchQueue.global().async {
            let (code, _) = run("/bin/launchctl", ["print", "gui/\(getuid())/\(receiverLabel)"])
            DispatchQueue.main.async { self.receiverUp = code == 0 }
        }
    }
}

enum Sender {
    static func send(_ urls: [URL]) {
        urls.forEach(sendOne)
    }

    // One tailscale process per file, so each row gets its own status.
    // Taildrop only carries files, so a folder goes as Folder.zip.
    private static func sendOne(_ url: URL) {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) else { return }
        let id = UUID().uuidString
        let name = url.lastPathComponent + (isDir.boolValue ? ".zip" : "")
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? nil
        History.shared.append(Event(id: id, at: Date().timeIntervalSince1970, dir: "out", name: name,
                                    bytes: isDir.boolValue ? nil : size, path: url.path,
                                    status: "sending", detail: "to \(peer)"))
        History.shared.sending += 1

        DispatchQueue.global(qos: .userInitiated).async {
            var file = url
            var tmp: URL?
            var result: (Int32, String) = (0, "")
            if isDir.boolValue {
                let dir = FileManager.default.temporaryDirectory.appendingPathComponent(id)
                try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                tmp = dir
                file = dir.appendingPathComponent(name)
                result = run("/usr/bin/ditto", ["-c", "-k", "--keepParent", url.path, file.path])
            }
            if result.0 == 0 {
                result = run(tailscale, ["file", "cp", file.path, "\(peer):"])
            }
            let bytes = (try? FileManager.default.attributesOfItem(atPath: file.path)[.size] as? Int64) ?? nil
            if let tmp { try? FileManager.default.removeItem(at: tmp) }

            DispatchQueue.main.async {
                let ok = result.0 == 0
                let why = result.1.split(separator: "\n").last.map(String.init) ?? "exit \(result.0)"
                History.shared.append(Event(id: id, at: Date().timeIntervalSince1970, dir: "out",
                                            name: name, bytes: bytes, path: nil,
                                            status: ok ? "done" : "failed",
                                            detail: ok ? "to \(peer)" : why))
                History.shared.sending -= 1
                notify(title: ok ? "Sent \(name)" : "Couldn't send \(name)",
                       body: ok ? "Delivered to \(peer)" : why, path: url.path)
            }
        }
    }

    static func chooseAndSend() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = true
        panel.prompt = "Send to \(peer)"
        NSApp.activate(ignoringOtherApps: true)
        if panel.runModal() == .OK { send(panel.urls) }
    }
}

func notify(title: String, body: String, path: String?) {
    let content = UNMutableNotificationContent()
    content.title = title
    content.body = body
    if let path { content.userInfo = ["path": path] }
    UNUserNotificationCenter.current().add(
        UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
}

func sizeText(_ bytes: Int64?) -> String? {
    bytes.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) }
}

struct Row: View {
    let t: Transfer
    let now: Date

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: t.dir == "out" ? "arrow.up.circle.fill" : "arrow.down.circle.fill")
                .font(.title2)
                .foregroundStyle(t.dir == "out" ? Color.blue : Color.green)
            VStack(alignment: .leading, spacing: 2) {
                Text(t.name).lineLimit(1).truncationMode(.middle)
                Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            switch t.status {
            case "sending": ProgressView().controlSize(.small)
            case "failed": Image(systemName: "xmark.octagon.fill").foregroundStyle(.red).help(t.detail ?? "")
            default: EmptyView()
            }
        }
        .padding(.vertical, 3)
        .contentShape(Rectangle())
    }

    private var subtitle: String {
        let when = RelativeDateTimeFormatter().localizedString(for: t.at, relativeTo: now)
        let side = t.dir == "out" ? "to \(peer)" : "from \(peer)"
        let parts: [String?] = [sizeText(t.bytes), when, t.status == "failed" ? t.detail : side]
        return parts.compactMap { $0 }.joined(separator: " · ")
    }
}

struct ContentView: View {
    @ObservedObject var history = History.shared
    @State private var targeted = false

    var body: some View {
        VStack(spacing: 0) {
            dropZone.padding(14)
            Divider()
            if history.items.isEmpty {
                Spacer()
                Text("No transfers yet").foregroundStyle(.secondary)
                Spacer()
            } else {
                TimelineView(.periodic(from: .now, by: 30)) { ctx in
                    List(history.items) { t in
                        Row(t: t, now: ctx.date)
                            .onTapGesture(count: 2) { reveal(t.path) }
                            .contextMenu {
                                Button("Show in Finder") { reveal(t.path) }.disabled(t.path == nil)
                                if t.dir == "out", let p = t.path {
                                    Button("Send Again") { Sender.send([URL(fileURLWithPath: p)]) }
                                }
                            }
                    }
                }
            }
            Divider()
            footer.padding(.horizontal, 14).padding(.vertical, 8)
        }
        .frame(minWidth: 380, minHeight: 440)
    }

    private var dropZone: some View {
        RoundedRectangle(cornerRadius: 12)
            .strokeBorder(style: StrokeStyle(lineWidth: 2, dash: [7, 5]))
            .foregroundStyle(targeted ? Color.accentColor : Color.secondary.opacity(0.5))
            .background(RoundedRectangle(cornerRadius: 12)
                .fill(targeted ? Color.accentColor.opacity(0.12) : Color.clear))
            .frame(height: 110)
            .overlay(VStack(spacing: 6) {
                Image(systemName: "arrow.up.doc").font(.system(size: 28))
                Text("Drop files to send to \(peer)").font(.headline)
                Text("or drop them on the Dock icon").font(.caption).foregroundStyle(.secondary)
            })
            .onDrop(of: [.fileURL], isTargeted: $targeted) { providers in
                let group = DispatchGroup()
                var urls: [URL] = []
                let lock = NSLock()
                for p in providers {
                    group.enter()
                    _ = p.loadObject(ofClass: URL.self) { url, _ in
                        if let url { lock.lock(); urls.append(url); lock.unlock() }
                        group.leave()
                    }
                }
                group.notify(queue: .main) { Sender.send(urls) }
                return true
            }
    }

    private var footer: some View {
        HStack {
            Circle().fill(history.receiverUp ? Color.green : Color.red).frame(width: 8, height: 8)
            Text(history.receiverUp ? "Receiving into Downloads" : "Receiver not running")
                .font(.caption).foregroundStyle(.secondary)
            Spacer()
            Button("Send Files…") { Sender.chooseAndSend() }
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    var window: NSWindow!

    func applicationDidFinishLaunching(_ note: Notification) {
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.requestAuthorization(options: [.alert, .sound]) { _, _ in }

        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 420, height: 520),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable],
                          backing: .buffered, defer: false)
        window.title = "ServerDrop"
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: ContentView())
        window.center()
        window.setFrameAutosaveName("ServerDrop")
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    // Files dropped on the Dock tile (or opened with the app) are sent.
    func application(_ sender: NSApplication, open urls: [URL]) {
        Sender.send(urls)
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        window.makeKeyAndOrderFront(nil)
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        let menu = NSMenu()
        for t in History.shared.items.prefix(8) {
            let item = NSMenuItem(title: (t.dir == "out" ? "↑ " : "↓ ") + t.name,
                                  action: #selector(revealItem(_:)), keyEquivalent: "")
            item.representedObject = t.path
            item.target = self
            item.isEnabled = t.path != nil
            menu.addItem(item)
        }
        if !menu.items.isEmpty { menu.addItem(.separator()) }
        let send = NSMenuItem(title: "Send Files…", action: #selector(chooseFiles), keyEquivalent: "")
        send.target = self
        menu.addItem(send)
        return menu
    }

    @objc func revealItem(_ item: NSMenuItem) { reveal(item.representedObject as? String) }
    @objc func chooseFiles() { Sender.chooseAndSend() }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent n: UNNotification,
                                withCompletionHandler done: @escaping (UNNotificationPresentationOptions) -> Void) {
        done([.banner, .sound])
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive r: UNNotificationResponse,
                                withCompletionHandler done: @escaping () -> Void) {
        reveal(r.notification.request.content.userInfo["path"] as? String)
        done()
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
