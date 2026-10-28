import AppKit
import AVFoundation
import SwiftUI

struct HistoryItem: Codable, Identifiable {
    var id = UUID()
    var path: String
    var date: Date
    var kind: String // "screenshot", "recording", "gif"
    var text: String = "" // recognized text, used for search

    var url: URL { URL(fileURLWithPath: path) }
    var exists: Bool { FileManager.default.fileExists(atPath: path) }
}

/// Everything Tack has saved, newest first. Stored as one small JSON file in Application Support.
@MainActor
final class History: ObservableObject {
    static let shared = History()
    @Published private(set) var items: [HistoryItem] = []

    private let fileURL: URL

    private init() {
        fileURL = AppFolders.supportFolder.appendingPathComponent("history.json")
        if let data = try? Data(contentsOf: fileURL),
           let decoded = try? JSONDecoder().decode([HistoryItem].self, from: data) {
            items = decoded
        }
    }

    func add(url: URL, kind: String, image: CGImage? = nil) {
        let item = HistoryItem(path: url.path, date: Date(), kind: kind)
        items.insert(item, at: 0)
        persist()
        if let image {
            let id = item.id
            Task {
                let result = await Scanner.scan(image, wantText: true, wantCodes: false)
                guard !result.text.isEmpty else { return }
                if let i = items.firstIndex(where: { $0.id == id }) {
                    items[i].text = result.text
                    persist()
                }
            }
        }
    }

    func remove(_ item: HistoryItem) {
        items.removeAll { $0.id == item.id }
        persist()
    }

    func clear() {
        items.removeAll()
        persist()
    }

    func recent(_ n: Int) -> [HistoryItem] {
        Array(items.filter { $0.exists }.prefix(n))
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(items) {
            try? data.write(to: fileURL, options: .atomic)
        }
    }
}

// MARK: Window

private struct HistoryView: View {
    @ObservedObject var history = History.shared
    @StateObject private var query = Field("")

    private var filtered: [HistoryItem] {
        let q = query.value.trimmingCharacters(in: .whitespaces).lowercased()
        let all = history.items
        if q.isEmpty { return all }
        return all.filter {
            $0.url.lastPathComponent.lowercased().contains(q) || $0.text.lowercased().contains(q)
        }
    }

    /// Items grouped under "Today", "Yesterday" or the date, newest first.
    private var groups: [(title: String, items: [HistoryItem])] {
        let cal = Calendar.current
        var order: [Date] = []
        var buckets: [Date: [HistoryItem]] = [:]
        for item in filtered {
            let day = cal.startOfDay(for: item.date)
            if buckets[day] == nil { order.append(day) }
            buckets[day, default: []].append(item)
        }
        return order.map { day in
            let title: String
            if cal.isDateInToday(day) { title = "Today" }
            else if cal.isDateInYesterday(day) { title = "Yesterday" }
            else { title = day.formatted(date: .complete, time: .omitted) }
            return (title, buckets[day] ?? [])
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("Search names and text inside screenshots", text: $query.value)
                        .textFieldStyle(.plain)
                    if !query.value.isEmpty {
                        Button { query.value = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                            .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(.quaternary.opacity(0.6), in: Capsule())

                Button("Clear All") { history.clear() }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
                    .help("Removes the list only. Your files are not deleted.")
            }
            .padding(.horizontal, 16)
            .padding(.top, 44)
            .padding(.bottom, 12)

            if filtered.isEmpty {
                Spacer()
                VStack(spacing: 8) {
                    Image(systemName: history.items.isEmpty ? "photo.on.rectangle.angled" : "magnifyingglass")
                        .font(.system(size: 34))
                        .foregroundStyle(.tertiary)
                    Text(history.items.isEmpty ? "Nothing saved yet" : "No matches")
                        .font(.headline)
                        .foregroundStyle(.secondary)
                    if history.items.isEmpty {
                        Text("Screenshots and recordings you save will show up here.")
                            .font(.callout)
                            .foregroundStyle(.tertiary)
                    }
                }
                Spacer()
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 8, pinnedViews: []) {
                        ForEach(groups, id: \.title) { group in
                            Text(group.title)
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(.secondary)
                                .padding(.top, 10)
                                .padding(.leading, 4)
                            ForEach(group.items) { item in
                                HistoryRow(item: item)
                            }
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 16)
                }
            }
        }
        .frame(minWidth: 600, minHeight: 420)
    }
}

private struct HistoryRow: View {
    let item: HistoryItem

    var body: some View {
        HStack(spacing: 14) {
            Thumb(item: item)
                .frame(width: 96, height: 64)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            VStack(alignment: .leading, spacing: 3) {
                Text(item.url.lastPathComponent)
                    .font(.system(size: 14, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                HStack(spacing: 6) {
                    Image(systemName: kindSymbol).font(.caption).foregroundStyle(.secondary)
                    Text(item.date.formatted(date: .omitted, time: .shortened) + (item.exists ? "" : " · file missing"))
                        .font(.caption)
                        .foregroundStyle(item.exists ? Color.secondary : Color.orange)
                }
            }
            Spacer(minLength: 8)
            HStack(spacing: 2) {
                if item.exists {
                    if item.kind != "recording" && item.kind != "gif" {
                        IconAction("pencil.tip", "Edit") { Editor.open(file: item.url) }
                        IconAction("pin", "Pin as a preview") { QuickAccess.shared.pinFile(item.url) }
                    } else if item.kind == "recording" {
                        IconAction("scissors", "Trim video") { VideoEditor.open(item.url) }
                    }
                    IconAction("arrow.up.forward.app", "Open") { NSWorkspace.shared.open(item.url) }
                    IconAction("magnifyingglass", "Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([item.url]) }
                }
                IconAction("xmark", "Remove from history (keeps the file)") { History.shared.remove(item) }
            }
        }
        .padding(10)
        .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .opacity(item.exists ? 1 : 0.7)
    }

    private var kindSymbol: String {
        switch item.kind {
        case "recording": return "video.fill"
        case "gif": return "livephoto"
        default: return "photo"
        }
    }
}

private struct IconAction: View {
    let symbol: String
    let tip: String
    let action: () -> Void

    init(_ symbol: String, _ tip: String, action: @escaping () -> Void) {
        self.symbol = symbol
        self.tip = tip
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .medium))
                .frame(width: 30, height: 30)
                .contentShape(Circle())
        }
        .buttonStyle(.borderless)
        .help(tip)
    }
}

/// A picture of the file: the image itself, or the first frame of a video.
private struct Thumb: NSViewRepresentable {
    let item: HistoryItem

    func makeNSView(context: Context) -> NSImageView {
        let v = NSImageView()
        v.imageScaling = .scaleProportionallyUpOrDown
        v.wantsLayer = true
        v.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.25).cgColor
        v.image = NSWorkspace.shared.icon(forFile: item.path)
        let path = item.path
        let kind = item.kind
        DispatchQueue.global(qos: .utility).async {
            var image: NSImage?
            if kind == "recording" {
                let gen = AVAssetImageGenerator(asset: AVURLAsset(url: URL(fileURLWithPath: path)))
                gen.appliesPreferredTrackTransform = true
                gen.maximumSize = CGSize(width: 288, height: 192)
                if let cg = try? gen.copyCGImage(at: CMTime(seconds: 0.3, preferredTimescale: 600), actualTime: nil) {
                    image = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
                }
            } else if let img = NSImage(contentsOfFile: path) {
                image = img.resized(toFit: NSSize(width: 288, height: 192))
            }
            if let image { DispatchQueue.main.async { v.image = image; v.imageScaling = .scaleProportionallyUpOrDown } }
        }
        return v
    }

    func updateNSView(_ nsView: NSImageView, context: Context) {}
}

extension NSImage {
    func resized(toFit box: NSSize) -> NSImage {
        let s = min(box.width / max(size.width, 1), box.height / max(size.height, 1), 1)
        let target = NSSize(width: size.width * s, height: size.height * s)
        let out = NSImage(size: target)
        out.lockFocus()
        draw(in: NSRect(origin: .zero, size: target), from: .zero, operation: .copy, fraction: 1)
        out.unlockFocus()
        return out
    }
}

@MainActor
enum HistoryWindow {
    private static var window: NSWindow?

    static func show() {
        if window == nil {
            let w = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 620, height: 460),
                styleMask: [.titled, .closable, .resizable, .miniaturizable, .fullSizeContentView],
                backing: .buffered,
                defer: false
            )
            w.title = "Capture History"
            w.titlebarAppearsTransparent = true
            w.contentViewController = NSHostingController(rootView: HistoryView())
            w.isReleasedWhenClosed = false
            w.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
            w.center()
            window = w
        }
        if window?.isVisible != true { window?.centerOnPointerScreen() }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}
