import Foundation

struct LyricLine {
    let time: Double
    let text: String
}

/// 歌词：网易云公开接口按「歌名+歌手」搜索 → 拉取 LRC → 按进度取当前行
@MainActor
final class LyricsService {
    private var cache: [String: [LyricLine]] = [:]
    private(set) var lines: [LyricLine] = []
    private(set) var loadedKey: String?

    func loadIfNeeded(title: String, artist: String, completion: (() -> Void)? = nil) {
        let key = "\(title)|\(artist)"
        guard loadedKey != key else { return }
        loadedKey = key
        if let cached = cache[key] {
            lines = cached
            completion?()
            return
        }
        lines = []
        let query = [title, artist].filter { !$0.isEmpty }.joined(separator: " ")
        guard let encoded = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let searchURL = URL(string: "https://music.163.com/api/search/get/web?s=\(encoded)&type=1&limit=5") else {
            completion?()
            return
        }
        var searchRequest = URLRequest(url: searchURL)
        searchRequest.setValue("music.163.com", forHTTPHeaderField: "Referer")
        searchRequest.setValue("Mozilla/5.0", forHTTPHeaderField: "User-Agent")
        searchRequest.timeoutInterval = 6

        URLSession.shared.dataTask(with: searchRequest) { [weak self] data, _, _ in
            guard let self, let data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let result = json["result"] as? [String: Any],
                  let songs = result["songs"] as? [[String: Any]], !songs.isEmpty else {
                DispatchQueue.main.async { completion?() }
                return
            }
            // 优先挑歌名相近的条目
            let needle = title.lowercased().prefix(10)
            let picked = songs.first { song in
                (song["name"] as? String)?.lowercased().contains(needle) == true
            } ?? songs[0]
            guard let songID = picked["id"] as? Int,
                  let lyricURL = URL(string: "https://music.163.com/api/song/lyric?id=\(songID)&lv=1") else {
                DispatchQueue.main.async { completion?() }
                return
            }
            var lyricRequest = URLRequest(url: lyricURL)
            lyricRequest.setValue("music.163.com", forHTTPHeaderField: "Referer")
            lyricRequest.timeoutInterval = 6
            URLSession.shared.dataTask(with: lyricRequest) { [weak self] lyricData, _, _ in
                guard let self, let lyricData,
                      let lyricJSON = try? JSONSerialization.jsonObject(with: lyricData) as? [String: Any],
                      let lrc = lyricJSON["lrc"] as? [String: Any],
                      let lrcText = lrc["lyric"] as? String else {
                    DispatchQueue.main.async { completion?() }
                    return
                }
                let parsed = Self.parseLRC(lrcText)
                DispatchQueue.main.async {
                    self.cache[key] = parsed
                    if self.loadedKey == key {
                        self.lines = parsed
                    }
                    completion?()
                }
            }.resume()
        }.resume()
    }

    /// 二分当前进度对应的歌词行
    func currentLine(position: Double) -> String? {
        guard !lines.isEmpty else { return nil }
        var low = 0, high = lines.count - 1
        var answer: LyricLine?
        while low <= high {
            let mid = (low + high) / 2
            if lines[mid].time <= position + 0.15 {
                answer = lines[mid]
                low = mid + 1
            } else {
                high = mid - 1
            }
        }
        let text = answer?.text ?? ""
        return text.isEmpty ? nil : text
    }

    nonisolated private static func parseLRC(_ text: String) -> [LyricLine] {
        var result: [(Double, String)] = []
        guard let regex = try? NSRegularExpression(pattern: #"\[(\d+):(\d+(?:\.\d+)?)\]"#) else {
            return []
        }
        for rawLine in text.components(separatedBy: .newlines) {
            let nsLine = rawLine as NSString
            let matches = regex.matches(in: rawLine, range: NSRange(location: 0, length: nsLine.length))
            guard !matches.isEmpty else { continue }
            let textRange = NSRange(location: matches.last!.range.upperBound, length: max(0, nsLine.length - matches.last!.range.upperBound))
            let content = nsLine.substring(with: textRange)
                .trimmingCharacters(in: .whitespaces)
            guard !content.isEmpty else { continue }
            for match in matches {
                let minutes = Double(nsLine.substring(with: match.range(at: 1))) ?? 0
                let seconds = Double(nsLine.substring(with: match.range(at: 2))) ?? 0
                result.append((minutes * 60 + seconds, content))
            }
        }
        return result.sorted { $0.0 < $1.0 }.map { LyricLine(time: $0.0, text: $0.1) }
    }
}
