import Foundation

// MARK: - 蓝牙帧收发留档
//
// 为什么必须有这个（2026-10-01 定论）：
//   两份官方 App 抓包（共 273 条请求）证明 **ifino 云端没有任何 REST 控车端点**——
//   全部请求都是 GET 只读（车况/列表/轨迹/菜单/用户信息/授权），一个写操作都没有；
//   官方 App 自己的界面文案也写着「待左上角蓝牙连接后点击解锁」。
//   → 控车**只能**走近车 BLE，而 BLE 指令帧目前还未经真车校准。
//
//   所以必须先把「观测点」装好：App 每次发出什么帧、车机回了什么，
//   全部落盘到 Documents/ble-trace.log（已通过 UIFileSharingEnabled 暴露给「文件」App）。
//   这样用户在车上点一次解锁，把日志导出来发我，就能对照校准帧格式；
//   比对「安卓 HCI 蓝牙日志」时也有 App 侧的时间线做参照。

public enum BLETrace {
    public static let fileName = "ble-trace.log"

    private static let maxBytes = 48 * 1024
    private static let snippetLimit = 800

    private static let stamp: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MM-dd HH:mm:ss.SSS"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    private static var url: URL? {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first?
            .appendingPathComponent(fileName)
    }

    /// 落盘是「读全文→拼接→写回」，多并发域同时调会互相覆盖（车身帧一多就丢行）。
    /// 全部收口到一条串行队列（同步执行，不会重入，不会死锁）。
    private static let queue = DispatchQueue(label: "com.shiqixiaoyao.zontesrider.bletrace")

    /// 记一条。dir 用 TX（发出）/ RX（收到）/ EVT（链路事件）
    public static func log(_ dir: String, _ text: String) {
        queue.sync { append(dir, text) }
    }

    private static func append(_ dir: String, _ text: String) {
        guard let url else { return }
        let flat = text
            .replacingOccurrences(of: "\r", with: "\\r")
            .replacingOccurrences(of: "\n", with: "\\n")
        let clipped = flat.count > snippetLimit ? String(flat.prefix(snippetLimit)) + "…" : flat
        let line = "[\(stamp.string(from: Date()))] \(dir) \(clipped)\n"

        var acc = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        acc += line
        if acc.utf8.count > maxBytes {
            acc = "[…已截断，只留最近记录…]\n" + String(acc.suffix(maxBytes / 2))
        }
        try? acc.data(using: .utf8)?.write(to: url, options: .atomic)
    }

    public static func tail(limit: Int = 1600) -> String {
        queue.sync {
            guard let url, let t = try? String(contentsOf: url, encoding: .utf8) else { return "" }
            return t.count > limit ? String(t.suffix(limit)) : t
        }
    }

    public static func clear() {
        queue.sync {
            guard let url else { return }
            try? FileManager.default.removeItem(at: url)
        }
    }
}
