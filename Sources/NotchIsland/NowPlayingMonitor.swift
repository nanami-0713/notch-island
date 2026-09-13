import AppKit
import Darwin
import Foundation
import SwiftUI

enum MusicCommand {
    case playPause, next, previous
}

/// "正在播放"数据源：MediaRemoteAdapter 助手（perl 宿主 dlopen，绕过 macOS 15.4+ 封锁）
/// 采用每 2 秒 `get --now` 轮询"已定格"的权威元数据——换歌瞬间的事件流会推中间态
/// （先 artist 后 title 之类），轮询拿到的永远是补全后的结果，配合本地插值平滑进度。
/// 助手不可用时兜底：AppleScript 轮询 Music / Spotify / 网易云等。
@MainActor
final class NowPlayingMonitor {
    var onUpdate: ((NowPlaying?) -> Void)?

    private enum Source {
        case helper
        case appleScript
    }

    private struct MusicApp {
        let bundleID: String
        let displayName: String
        var script: NSAppleScript?
    }

    /// AppleScript 兜底支持的播放器：装了且在运行才会被轮询。
    /// 酷狗（正式版/概念版）无 AppleScript 词典，不进此列表——其信息走 MediaRemote 助手，控制走模拟媒体键
    private static let supportedApps: [(bundleID: String, displayName: String)] = [
        ("com.apple.Music", "Music"),
        ("com.spotify.client", "Spotify"),
        ("com.netease.163music", "网易云音乐"),
        ("com.tencent.QQMusicMac", "QQ音乐"),
    ]

    private static let displayNames = [
        "com.apple.Music": "Music",
        "com.spotify.client": "Spotify",
        "com.netease.163music": "网易云音乐",
        "com.kugou.mac.Music": "酷狗音乐",
        "com.kugou.kgyouth": "酷狗音乐(概念版)",
        "com.tencent.QQMusicMac": "QQ音乐",
    ]

    private var timer: Timer?
    private var tickCount = 0
    private var rawLogCount = 0
    private var helperAvailable = true
    private var helperFailures = 0
    private var musicApps: [MusicApp] = []
    private var lastAppBundleID: String?
    private var lastSource: Source = .helper
    private var lastInfo: NowPlaying?
    private var estimateBase: Double = 0
    private var estimateDate = Date()
    private var lastArtworkData: Data?
    private var lastArtworkImage: NSImage?
    private var lastArtworkTint: Color?
    private static var artworkWarned = false

    func start() {
        let timer = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func shutdown() {
        timer?.invalidate()
        timer = nil
    }

    /// 对外提供插值后的播放进度，让进度条平滑走动
    func currentEstimate() -> NowPlaying? {
        guard var np = lastInfo else { return nil }
        if np.playing {
            np.position = estimateBase + Date().timeIntervalSince(estimateDate)
        }
        return np
    }

    func send(_ command: MusicCommand) {
        switch lastSource {
        case .helper:
            let code: Int
            switch command {
            case .playPause: code = 2   // kMRATogglePlayPause
            case .next: code = 4        // kMRANextTrack
            case .previous: code = 5    // kMRAPreviousTrack
            }
            runHelper(["send", "\(code)"])
        case .appleScript:
            guard let bundleID = lastAppBundleID else { return }
            let verb: String
            switch command {
            case .playPause: verb = "playpause"
            case .next: verb = "next track"
            case .previous: verb = "previous track"
            }
            _ = Self.runScript("tell application id \"\(bundleID)\" to \(verb)")
        }
    }

    /// 短暂子进程：发送一次控制命令
    private func runHelper(_ args: [String]) {
        guard helperFilesExist else { return }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
        process.arguments = [helperPerl, helperFramework] + args
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + 5) { [weak process] in
            if let process, process.isRunning {
                process.terminate()
            }
        }
    }

    private func tick() {
        tickCount += 1
        guard helperAvailable else {
            pollAppleScript()
            return
        }
        // get 每 2 秒一次；启动先拍一发
        if tickCount == 1 || tickCount % 2 == 0 {
            fetchGet()
        }
    }

    // MARK: - 助手子进程

    private var helperPerl: String {
        Bundle.main.resourceURL?.appendingPathComponent("MediaRemoteAdapter/mediaremote-adapter.pl").path
            ?? "/usr/bin/false"
    }

    private var helperFramework: String {
        Bundle.main.resourceURL?.appendingPathComponent("MediaRemoteAdapter/MediaRemoteAdapter.framework").path
            ?? "/usr/bin/false"
    }

    private var helperFilesExist: Bool {
        FileManager.default.fileExists(atPath: helperPerl)
            && FileManager.default.fileExists(atPath: helperFramework)
    }

    private func fetchGet() {
        guard helperFilesExist else {
            IslandController.debugLog("helper files missing: perl=\(helperPerl) fw=\(helperFramework)")
            helperAvailable = false
            pollAppleScript()
            return
        }
        if rawLogCount == 0 {
            IslandController.debugLog("fetchGet spawn perl=\(helperPerl) fw=\(helperFramework)")
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
        process.arguments = [helperPerl, helperFramework, "get", "--now"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        // 输出含 base64 封面（150KB+）会超过 64KB 管道缓冲：
        // 必须并发读取，"等进程退出再读"会与子进程互相等待死锁
        let bufferLock = NSLock()
        let buffer = NSMutableData()
        pipe.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            if chunk.isEmpty {
                handle.readabilityHandler = nil
                return
            }
            bufferLock.lock()
            buffer.append(chunk)
            bufferLock.unlock()
        }

        var finished = false
        process.terminationHandler = { [weak self] _ in
            pipe.fileHandleForReading.readabilityHandler = nil
            let rest = pipe.fileHandleForReading.readDataToEndOfFile()
            bufferLock.lock()
            buffer.append(rest)
            let output = buffer as Data
            bufferLock.unlock()
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, !finished else { return }
                    finished = true
                    self.handleGetOutput(output)
                }
            }
        }
        do {
            try process.run()
        } catch {
            helperFail(handleError: error.localizedDescription)
            return
        }
        // 兜底：助手 10 秒未退出视为挂起（XPC 无响应等），杀掉按失败计
        DispatchQueue.global().asyncAfter(deadline: .now() + 10) { [weak process, weak self] in
            guard let process, process.isRunning else { return }
            process.terminate()
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, !finished else { return }
                    finished = true
                    self.helperFail(handleError: "get timed out after 10s")
                }
            }
        }
    }

    private func handleGetOutput(_ data: Data) {
        let line = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        // 临时诊断：前 15 次轮询落盘原始输出
        rawLogCount += 1
        if rawLogCount <= 15 {
            IslandController.debugLog("get raw[\(rawLogCount)]: \(String(line.prefix(150)))")
        }
        guard !line.isEmpty else {
            helperFail(handleError: "empty output")
            return
        }
        helperFailures = 0
        if line == "null" {
            apply(nil)
            return
        }
        guard let payload = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any] else {
            helperFail(handleError: "unparseable output")
            return
        }
        lastSource = .helper
        handlePayload(payload)
    }

    private func helperFail(handleError: String) {
        helperFailures += 1
        IslandController.debugLog("helper get failed #\(helperFailures): \(handleError)")
        if helperFailures >= 3 {
            helperAvailable = false
            IslandController.debugLog("helper disabled, falling back to AppleScript")
        }
    }

    private func handlePayload(_ payload: [String: Any]) {
        var title = payload["title"] as? String ?? ""
        let artist = payload["artist"] as? String ?? ""
        // 部分电台把歌手名放进 title 字段、歌名缺失：用 artist 兜底当标题，避免两行重复
        if title.isEmpty && !artist.isEmpty {
            title = artist
        }
        if title.isEmpty {
            apply(nil)
            return
        }
        let displayArtist = artist == title ? "" : artist

        let bundleID = payload["bundleIdentifier"] as? String
        let duration = payload["duration"] as? Double ?? 0
        let position = payload["elapsedTimeNow"] as? Double ?? payload["elapsedTime"] as? Double ?? 0
        let rate = payload["playbackRate"] as? Double ?? 0

        var artwork = lastArtworkImage
        var tint = lastArtworkTint
        if let base64 = payload["artworkData"] as? String, let data = Data(base64Encoded: base64) {
            if data != lastArtworkData, let image = NSImage(data: data) {
                lastArtworkData = data
                lastArtworkImage = image
                lastArtworkTint = Self.dominantColor(of: image)
            }
            artwork = lastArtworkImage
            tint = lastArtworkTint
        }

        let nowPlaying = NowPlaying(
            title: title,
            artist: displayArtist,
            app: bundleID.flatMap { Self.displayNames[$0] } ?? "",
            duration: duration,
            position: max(0, position),
            playing: rate > 0,
            controlsEnabled: true,
            artwork: artwork,
            tint: tint
        )
        lastAppBundleID = bundleID
        apply(nowPlaying)
    }

    /// 从封面提取主色调（8×8 降采样平均 + 提亮），用于声纹着色
    private static func dominantColor(of image: NSImage) -> Color? {
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            return nil
        }
        let side = 8
        guard let context = CGContext(
            data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.interpolationQuality = .low
        context.draw(cg, in: CGRect(x: 0, y: 0, width: side, height: side))
        guard let data = context.data else { return nil }
        let pixels = data.bindMemory(to: UInt8.self, capacity: side * side * 4)
        var r = 0.0, g = 0.0, b = 0.0
        for i in 0..<(side * side) {
            let alpha = Double(pixels[i * 4 + 3]) / 255.0
            guard alpha > 0.1 else { continue }
            r += Double(pixels[i * 4]) * alpha
            g += Double(pixels[i * 4 + 1]) * alpha
            b += Double(pixels[i * 4 + 2]) * alpha
        }
        let boost = 1.3
        return Color(
            red: min(1, 0.18 + r / Double(side * side) / 255 * boost),
            green: min(1, 0.18 + g / Double(side * side) / 255 * boost),
            blue: min(1, 0.18 + b / Double(side * side) / 255 * boost)
        )
    }

    private func apply(_ np: NowPlaying?) {
        if let np {
            lastInfo = np
            estimateBase = np.position
            estimateDate = Date()
        } else {
            lastInfo = nil
        }
        onUpdate?(lastInfo)
    }

    // MARK: - AppleScript 兜底

    private func pollAppleScript() {
        if musicApps.isEmpty {
            musicApps = Self.supportedApps.map {
                MusicApp(bundleID: $0.bundleID, displayName: $0.displayName, script: nil)
            }
        }

        var best: NowPlaying?
        var bestBundle: String?
        var foundPlaying = false
        for index in musicApps.indices {
            let app = musicApps[index]
            guard !NSRunningApplication.runningApplications(withBundleIdentifier: app.bundleID).isEmpty else { continue }
            if musicApps[index].script == nil {
                musicApps[index].script = NSAppleScript(source: Self.querySource(bundleID: app.bundleID))
            }
            guard let parsed = parse(Self.run(musicApps[index].script), app: app.displayName) else {
                if best == nil && bestBundle == nil {
                    bestBundle = app.bundleID
                }
                continue
            }
            if parsed.playing {
                best = parsed
                bestBundle = app.bundleID
                foundPlaying = true
                break
            }
            if !foundPlaying && best == nil {
                best = parsed
                bestBundle = app.bundleID
            }
        }
        lastAppBundleID = bestBundle
        lastSource = .appleScript
        apply(best)
    }

    private func parse(_ raw: String?, app: String) -> NowPlaying? {
        guard let raw, !raw.isEmpty else { return nil }
        var parts = raw.components(separatedBy: "|")
        guard parts.count >= 5 else { return nil }
        let state = parts.removeLast()
        let position = Double(parts.removeLast()) ?? 0
        let duration = Double(parts.removeLast()) ?? 0
        let artist = parts.removeLast()
        let title = parts.joined(separator: "|")
        guard !title.isEmpty else { return nil }
        return NowPlaying(
            title: title,
            artist: artist,
            app: app,
            duration: duration,
            position: position,
            playing: state == "playing",
            controlsEnabled: true,
            artwork: nil,
            tint: nil
        )
    }

    private static func querySource(bundleID: String) -> String {
        #"""
tell application id "\#(bundleID)"
	set st to (player state as string)
	if st is "stopped" then return ""
	set t to ""
	set ar to ""
	set du to 0
	set p to 0
	try
		set t to name of current track
		set ar to artist of current track
		set du to duration of current track
		set p to player position
	end try
	if t is "" then return ""
	return t & "|" & ar & "|" & (du as string) & "|" & (p as string) & "|" & st
end tell
"""#
    }

    private static func run(_ script: NSAppleScript?) -> String? {
        guard let script else { return nil }
        var error: NSDictionary?
        let descriptor = script.executeAndReturnError(&error)
        if error != nil { return nil }
        return descriptor.stringValue
    }

    private static func runScript(_ source: String) -> String? {
        guard let script = NSAppleScript(source: source) else { return nil }
        return run(script)
    }
}
