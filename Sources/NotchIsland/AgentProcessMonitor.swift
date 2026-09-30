import Darwin
import Foundation

/// 每 5s 扫进程表：是否存在 ZCode CLI 会话进程（zcode-cli / zcode-host-local*）。
/// 只作 liveness 兜底——细粒度状态由 hooks 桥负责；进程消失用于识别"CLI 已退出"、
/// 清理桥来不及发 Stop 的鬼影会话。注意不能按路径含 "zcode" 匹配：
/// ZCode.app 的 GUI（Electron）进程路径也含 zcode，会永远误判存活
final class AgentProcessMonitor {
    private var timer: DispatchSourceTimer?

    func start(handler: @escaping (Bool) -> Void) {
        let queue = DispatchQueue(label: "agent-island.procmon", qos: .utility)
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: 5)
        timer.setEventHandler {
            let alive = Self.agentProcessExists()
            DispatchQueue.main.async { handler(alive) }
        }
        timer.resume()
        self.timer = timer
    }

    func stop() {
        timer?.cancel()
        timer = nil
    }

    private static func agentProcessExists() -> Bool {
        var pids = [pid_t](repeating: 0, count: 4096)
        let count = proc_listallpids(&pids, Int32(pids.count))
        guard count > 0 else { return false }
        for pid in pids.prefix(Int(count)) where pid > 0 {
            var path = [CChar](repeating: 0, count: Int(MAXPATHLEN))
            guard proc_pidpath(pid, &path, UInt32(path.count)) > 0 else { continue }
            let name = (String(cString: path) as NSString).lastPathComponent
            if name.hasPrefix("zcode-cli") || name.hasPrefix("zcode-host-local") {
                return true
            }
        }
        return false
    }
}
