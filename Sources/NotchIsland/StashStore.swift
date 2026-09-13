import AppKit
import Foundation

/// 文件暂存仓：拖进灵动岛的文件被移入 Application Support 下的 Inbox，
/// 记录原始位置，可一键取回
struct StashedFile: Codable, Equatable {
    var name: String
    var inboxName: String
    var originalPath: String
    var date: Date
}

final class StashStore {
    let inboxDir: URL
    private let manifestURL: URL
    private(set) var files: [StashedFile] = []

    init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("NotchIsland", isDirectory: true)
        inboxDir = base.appendingPathComponent("Inbox", isDirectory: true)
        manifestURL = base.appendingPathComponent("manifest.json")
        try? FileManager.default.createDirectory(at: inboxDir, withIntermediateDirectories: true)
        load()
    }

    @discardableResult
    func stash(urls: [URL]) -> Int {
        var added = 0
        for url in urls where url.isFileURL {
            let name = url.lastPathComponent
            var inboxName = name
            var n = 1
            while FileManager.default.fileExists(atPath: inboxDir.appendingPathComponent(inboxName).path) {
                let ext = url.pathExtension
                let base = ext.isEmpty ? name : String(name.dropLast(ext.count + 1))
                inboxName = ext.isEmpty ? "\(base)-\(n)" : "\(base)-\(n).\(ext)"
                n += 1
            }
            do {
                try FileManager.default.moveItem(at: url, to: inboxDir.appendingPathComponent(inboxName))
                files.append(StashedFile(
                    name: name,
                    inboxName: inboxName,
                    originalPath: url.deletingLastPathComponent().path,
                    date: Date()
                ))
                added += 1
            } catch {
                continue
            }
        }
        if added > 0 { save() }
        return added
    }

    /// 取出全部：移回各自原来的文件夹
    func unstashAll() {
        for file in files {
            let source = inboxDir.appendingPathComponent(file.inboxName)
            guard FileManager.default.fileExists(atPath: source.path) else { continue }
            let ext = (file.name as NSString).pathExtension
            let base = ext.isEmpty ? file.name : String(file.name.dropLast(ext.count + 1))
            var n = 1
            var destination = URL(fileURLWithPath: file.originalPath).appendingPathComponent(file.name)
            while FileManager.default.fileExists(atPath: destination.path) {
                let newName = ext.isEmpty ? "\(base)-\(n)" : "\(base)-\(n).\(ext)"
                destination = URL(fileURLWithPath: file.originalPath).appendingPathComponent(newName)
                n += 1
            }
            try? FileManager.default.moveItem(at: source, to: destination)
        }
        files.removeAll()
        save()
    }

    /// 拷贝全部：把暂存文件以文件 URL 写入剪贴板，可直接去别处粘贴
    @discardableResult
    func copyAllToPasteboard() -> Int {
        let urls = files.map { inboxDir.appendingPathComponent($0.inboxName) }
        guard !urls.isEmpty else { return 0 }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.writeObjects(urls.map { $0 as NSURL })
        return urls.count
    }

    /// 删除单个：移到废纸篓
    func trash(_ file: StashedFile) {
        let url = inboxDir.appendingPathComponent(file.inboxName)
        try? FileManager.default.trashItem(at: url, resultingItemURL: nil)
        files.removeAll { $0.inboxName == file.inboxName }
        save()
    }

    func reveal(_ file: StashedFile) {
        NSWorkspace.shared.activateFileViewerSelecting([inboxDir.appendingPathComponent(file.inboxName)])
    }

    func openInbox() {
        NSWorkspace.shared.open(inboxDir)
    }

    private func save() {
        if let data = try? JSONEncoder().encode(files) {
            try? data.write(to: manifestURL, options: .atomic)
        }
    }

    private func load() {
        guard let data = try? Data(contentsOf: manifestURL),
              let decoded = try? JSONDecoder().decode([StashedFile].self, from: data) else { return }
        files = decoded.filter { FileManager.default.fileExists(atPath: inboxDir.appendingPathComponent($0.inboxName).path) }
    }
}
