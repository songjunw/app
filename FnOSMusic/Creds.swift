import Foundation
import Security

/// 飞牛账号凭据。安卓版存在 fnOS App 的私有存储 + Keystore，iOS 用 Keychain 等价替代。
struct Creds {
    var origin = ""
    var user = ""
    var pass = ""
    var root = ""

    func valid() -> Bool {
        !origin.isEmpty && !user.isEmpty && !pass.isEmpty && !root.isEmpty
    }

    static let service = "com.fnos.music"

    static func load() -> Creds {
        Creds(origin: read(key: "origin"),
              user: read(key: "user"),
              pass: read(key: "pass"),
              root: read(key: "root"))
    }

    func save() {
        write(key: "origin", value: origin)
        write(key: "user", value: user)
        write(key: "pass", value: pass)
        write(key: "root", value: root)
    }

    static func clear() {
        for k in ["origin", "user", "pass", "root"] {
            SecItemDelete(query(key: k) as CFDictionary)
        }
    }

    // ---------- Keychain ----------

    private static func query(key: String) -> [CFString: Any] {
        [kSecClass: kSecClassGenericPassword,
         kSecAttrService: Creds.service,
         kSecAttrAccount: key]
    }

    private static func read(key: String) -> String {
        var q = query(key: key)
        q[kSecReturnData] = true
        q[kSecMatchLimit] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data,
              let s = String(data: data, encoding: .utf8) else { return "" }
        return s
    }

    private func write(key: String, value: String) {
        SecItemDelete(Creds.query(key: key) as CFDictionary)
        guard !value.isEmpty else { return }
        let q: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: Creds.service,
            kSecAttrAccount: key,
            kSecValueData: Data(value.utf8),
            kSecAttrAccessible: kSecAttrAccessibleAfterFirstUnlock,
        ]
        SecItemAdd(q as CFDictionary, nil)
    }
}
