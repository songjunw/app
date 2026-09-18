import Foundation

/// 同步过程落盘追踪。
///
/// 为什么需要它：Swift 的运行时陷阱（下标越界、跨字符串复用 Index、强制解包 nil）
/// 抛的是 fatal error，`do/catch` 根本接不住，App 直接闪退且不留痕迹。
/// 所以把同步的每一步都写盘；一旦崩了，下次打开就能看到"停在第几步"，
/// 直接定位问题，而不是靠猜。
enum SyncLog {

    private static let traceKey   = "fnos.syncTrace"
    private static let crashedKey = "fnos.syncCrashed"
    private static let timeKey    = "fnos.syncTraceTime"
    private static let maxLines   = 300
    private static let q = DispatchQueue(label: "com.fnos.synclog")

    /// 开始一次同步：先置"未正常结束"标记，只有 finish 才会清掉。
    /// 若中途崩溃，这个标记就会一直留着 → 下次启动据此提示用户。
    static func begin() {
        q.sync {
            let ud = UserDefaults.standard
            ud.set(true, forKey: crashedKey)
            ud.set([String](), forKey: traceKey)
            ud.set(Date().timeIntervalSince1970, forKey: timeKey)
            ud.synchronize()
        }
    }

    /// 记录一步（带时间戳）。崩溃前写的这些就是破案线索。
    static func step(_ msg: String) {
        q.sync {
            let ud = UserDefaults.standard
            var lines = ud.stringArray(forKey: traceKey) ?? []
            lines.append(stamp() + msg)
            if lines.count > maxLines { lines = Array(lines.suffix(maxLines)) }
            ud.set(lines, forKey: traceKey)
            ud.set(Date().timeIntervalSince1970, forKey: timeKey)
            ud.synchronize()
        }
    }

    static func finish(ok: Bool) {
        q.sync {
            let ud = UserDefaults.standard
            ud.set(false, forKey: crashedKey)
            var lines = ud.stringArray(forKey: traceKey) ?? []
            lines.append(stamp() + (ok ? "—— 同步完成" : "—— 同步失败"))
            ud.set(lines, forKey: traceKey)
            ud.synchronize()
        }
    }

    /// 上次同步是否没走到 finish（大概率是崩了 / 被系统杀掉）
    static var crashed: Bool {
        q.sync { UserDefaults.standard.bool(forKey: crashedKey) }
    }

    static var trace: String {
        q.sync {
            (UserDefaults.standard.stringArray(forKey: traceKey) ?? []).joined(separator: "\n")
        }
    }

    static func clear() {
        q.sync {
            let ud = UserDefaults.standard
            ud.set(false, forKey: crashedKey)
            ud.removeObject(forKey: traceKey)
            ud.synchronize()
        }
    }

    private static func stamp() -> String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return "[" + f.string(from: Date()) + "] "
    }
}
