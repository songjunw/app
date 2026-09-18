import Foundation
import CommonCrypto
import CryptoKit
import Security

/// fnOS（飞牛）FN Connect 中继协议客户端（Swift 复刻自安卓 FnosClient.java）。
///
/// 协议要点：
///  1. WSS 握手要带 Cookie: mode=relay，否则被 WAF 302 到登录页
///  2. 连上后发【未签名】{req:"util.crypto.getRSAPub"} → {pub, si}
///  3. 客户端自生成 32 字符 secret S；AES key = utf8(S)（32 字节 = AES-256），iv = 16 随机字节
///  4. 加密请求 = {req:"encrypted", iv:b64, rsa:b64(RSA_PKCS1v15(pub, utf8(S))), aes:b64(AES-256-CBC(json))}
///     ★ 内层 payload 必须带 si，否则返回 8192 E_PARAM_ERROR
///  5. 登录响应的 secret 字段用同一 AES key/iv 解密 → 得到 HMAC 签名密钥（16 字节）
///  6. 之后所有请求 = base64(HMAC-SHA256(json, hmacKey)) + json（服务端从第一个 '{' 切分）
///  7. 文件类 API 必须走 type=file 连接，且需先 util.getSI 再签名调 user.authToken
enum FnErr: Error, LocalizedError {
    case crypto, badPub, rsa, timeout, closed(String), proto(String), login(String)
    var errorDescription: String? {
        switch self {
        case .crypto: return "加密失败"
        case .badPub: return "RSA 公钥解析失败"
        case .rsa: return "RSA 加密失败"
        case .timeout: return "请求超时"
        case .closed(let r): return "连接中断: \(r)"
        case .proto(let m): return "协议错误: \(m)"
        case .login(let m): return "登录失败: \(m)"
        }
    }
}

final class FnosClient {

    static func errName(_ e: Int) -> String {
        switch e {
        case 4224:   return "未登录"
        case 4352:   return "权限不足"
        case 8192:   return "参数错误"
        case 65280:  return "非法操作"
        case 65534:  return "请求签名错误"
        case 65535:  return "未知错误"
        case 131072: return "用户名或密码错误"
        case 131073: return "用户不存在"
        default:     return "错误码 \(e)"
        }
    }

    private let ua = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 " +
                     "(KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36 Edg/131.0.0.0"

    let origin: String
    private let host: String
    private let cookie: String

    private let secretStr: String
    private let aesKey: Data
    private var iv: Data
    private var pub: String?
    private var si: Any?
    private var hmacKey: Data?
    private(set) var token = ""
    private(set) var longToken = ""
    private(set) var uid = 0

    /// 暴露给 SyncManager 在 main / file 两条连接之间传递会话状态
    func getToken() -> String { q.sync { token } }
    func getHmacKey() -> Data? { q.sync { hmacKey } }
    func setHmacKey(_ k: Data?) { q.sync { hmacKey = k } }

    // ---------- 线程安全 ----------
    private let q = DispatchQueue(label: "com.fnos.client")
    private var ws: URLSessionWebSocketTask?
    private var seq = 0
    private var pending: [String: Pending] = [:]
    private var recvTask: Task<Void, Never>?

    private struct Pending {
        var stream: Bool
        var files: [[String: Any]] = []
        var cont: CheckedContinuation<[String: Any], Error>
    }

    init(origin: String, cookie: String? = nil) {
        var o = origin.trimmingCharacters(in: .whitespacesAndNewlines)
        while o.hasSuffix("/") { o.removeLast() }
        self.origin = o
        if let p = o.range(of: "://") {
            self.host = String(o[o.index(p.lowerBound, offsetBy: 3)...])
        } else {
            self.host = o
        }
        self.cookie = (cookie != nil && !cookie!.isEmpty) ? cookie! : "language=zh-CN; mode=relay"

        let cs = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789"
        var s = ""
        for _ in 0..<32 { s.append(cs.randomElement()!) }
        self.secretStr = s
        self.aesKey = Data(s.utf8)
        var iv = Data(count: 16)
        _ = iv.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, 16, $0.baseAddress!) }
        self.iv = iv
    }

    // ---------- 连接 ----------

    func connect(type: String, timeout: TimeInterval = 20) async throws {
        guard let url = URL(string: "wss://\(host)/websocket?type=\(type)") else {
            throw FnErr.proto("非法地址")
        }
        var req = URLRequest(url: url)
        req.timeoutInterval = timeout
        req.setValue(ua, forHTTPHeaderField: "User-Agent")
        req.setValue(origin, forHTTPHeaderField: "Origin")
        req.setValue("zh-CN,zh;q=0.9", forHTTPHeaderField: "Accept-Language")
        req.setValue(cookie, forHTTPHeaderField: "Cookie")
        let ws = URLSession.shared.webSocketTask(with: req)
        self.ws = ws
        ws.resume()
        recvTask = Task { await runReceiver(ws) }
    }

    func close() {
        ws?.cancel(with: .normalClosure, reason: nil)
        ws = nil
        recvTask?.cancel()
        recvTask = nil
        failAll("closed")
    }

    private func runReceiver(_ ws: URLSessionWebSocketTask) async {
        while true {
            do {
                let msg = try await ws.receive()
                switch msg {
                case .string(let s): handle(s)
                case .data(let d):
                    if let s = String(data: d, encoding: .utf8) { handle(s) }
                @unknown default: break
                }
            } catch {
                failAll("recv: \(error.localizedDescription)")
                return
            }
        }
    }

    private func handle(_ text: String) {
        guard let j = text.firstIndex(of: "{") else { return }
        let jsonStr = String(text[j...])
        guard let data = jsonStr.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        guard let reqid = obj["reqid"] as? String else { return }
        var final: [String: Any]? = nil
        q.sync {
            guard var p = self.pending[reqid] else { return }
            if p.stream {
                if let files = obj["files"] as? [[String: Any]] { p.files.append(contentsOf: files) }
                if obj["result"] != nil || obj["errno"] != nil {
                    var f = obj
                    f["__files"] = p.files
                    self.pending[reqid] = p
                    final = f
                } else {
                    self.pending[reqid] = p
                }
            } else {
                let fin = obj["result"] != nil || obj["errno"] != nil ||
                          obj["pub"] != nil || obj["download"] != nil || obj["secret"] != nil
                if fin { self.pending[reqid] = p; final = obj }
            }
        }
        if let final = final { finish(reqid, .success(final)) }
    }

    /// 取出并移除 pending，恢复 continuation（保证只恢复一次，线程安全）
    private func finish(_ reqid: String, _ result: Result<[String: Any], Error>) {
        var cont: CheckedContinuation<[String: Any], Error>?
        q.sync {
            guard let p = self.pending.removeValue(forKey: reqid) else { return }
            cont = p.cont
        }
        if let cont = cont { cont.resume(with: result) }
    }

    private func failAll(_ reason: String) {
        let keys = q.sync { Array(pending.keys) }
        for k in keys { finish(k, .failure(FnErr.closed(reason))) }
    }

    // ---------- 收发 ----------

    private func request(payload: [String: Any], reqid: String, signed: Bool,
                         stream: Bool, timeout: TimeInterval) async throws -> [String: Any] {
        return try await withCheckedThrowingContinuation { cont in
            q.sync { self.pending[reqid] = Pending(stream: stream, cont: cont) }
            let wire: String
            do {
                let bodyData = try JSONSerialization.data(withJSONObject: payload)
                guard let body = String(data: bodyData, encoding: .utf8) else {
                    throw FnErr.proto("序列化失败")
                }
                if signed {
                    let key = q.sync { self.hmacKey } ?? Data()
                    wire = hmacBase64(key: key, data: bodyData) + body
                } else {
                    wire = body
                }
            } catch {
                q.sync { self.pending.removeValue(forKey: reqid) }
                cont.resume(throwing: error)
                return
            }
            self.ws?.send(.string(wire)) { err in
                if let err = err { self.finish(reqid, .failure(FnErr.proto(err.localizedDescription))) }
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                self.finish(reqid, .failure(FnErr.timeout))
            }
        }
    }

    func send(_ req: [String: Any], timeout: TimeInterval = 20) async throws -> [String: Any] {
        let reqid = newId()
        var r = req; r["reqid"] = reqid
        return try await request(payload: r, reqid: reqid, signed: true, stream: false, timeout: timeout)
    }

    func sendRaw(_ req: [String: Any], timeout: TimeInterval = 20) async throws -> [String: Any] {
        let reqid = newId()
        var r = req; r["reqid"] = reqid
        return try await request(payload: r, reqid: reqid, signed: false, stream: false, timeout: timeout)
    }

    func sendStream(_ req: [String: Any], timeout: TimeInterval = 40) async throws -> [[String: Any]] {
        let reqid = newId()
        var r = req; r["reqid"] = reqid
        let resp = try await request(payload: r, reqid: reqid, signed: true, stream: true, timeout: timeout)
        if let e = resp["errno"] as? Int, e != 0 { throw FnErr.proto(FnosClient.errName(e)) }
        return resp["__files"] as? [[String: Any]] ?? []
    }

    // ---------- 协议步骤 ----------

    func fetchPub() async throws {
        let r = try await sendRaw(["req": "util.crypto.getRSAPub"])
        guard let p = r["pub"] as? String, !p.isEmpty else { throw FnErr.proto("未取得 RSA 公钥") }
        pub = p
        si = r["si"]
    }

    func fetchSI() async throws {
        let r = try await sendRaw(["req": "util.getSI"])
        si = r["si"]
    }

    func login(user: String, password: String, deviceName: String = "iOS-Player") async throws {
        if pub == nil { try await fetchPub() }
        let reqid = newId()
        var inner: [String: Any] = [
            "reqid": reqid,
            "req": "user.login",
            "user": user,
            "password": password,
            "deviceName": deviceName,
            "deviceType": "Browser",
            "stay": true,
            "did": makeDid(),
        ]
        if let si = si { inner["si"] = si }
        var outer = try encrypt(inner: inner)
        outer["reqid"] = reqid
        let r = try await request(payload: outer, reqid: reqid, signed: false, stream: false, timeout: 30)
        if let e = r["errno"] as? Int, e != 0 { throw FnErr.login(FnosClient.errName(e)) }
        guard let sec = r["secret"] as? String, !sec.isEmpty else {
            throw FnErr.proto("登录响应缺少 secret")
        }
        hmacKey = try decryptSecret(sec)
        token = r["token"] as? String ?? ""
        longToken = r["longToken"] as? String ?? ""
        if token.isEmpty { throw FnErr.proto("登录响应缺少 token") }
    }

    func authToken(_ tk: String) async throws {
        var req: [String: Any] = ["req": "user.authToken", "token": tk, "main": true]
        if let si = si { req["si"] = si }
        let r = try await send(req)
        if let e = r["errno"] as? Int, e != 0 {
            throw FnErr.proto("文件通道认证失败：" + FnosClient.errName(e))
        }
        if let u = r["uid"] as? Int { uid = u }
    }

    // ---------- 文件 API ----------

    func ls(_ path: String) async throws -> [[String: Any]] {
        try await sendStream(["req": "file.ls", "path": path])
    }

    func lsDir(_ path: String) async throws -> [[String: Any]] {
        try await sendStream(["req": "file.lsDir", "path": path])
    }

    func download(_ paths: [String]) async throws -> [[String: Any]] {
        let r = try await send(["req": "file.download", "files": paths])
        if let e = r["errno"] as? Int, e > 0 { throw FnErr.proto(FnosClient.errName(e)) }
        return r["download"] as? [[String: Any]] ?? []
    }

    // ---------- 加密 ----------

    private func encrypt(inner: [String: Any]) throws -> [String: Any] {
        guard let pub = pub else { throw FnErr.proto("pub 缺失") }
        guard let si = si else { throw FnErr.proto("si 缺失") }
        var innerWithSi = inner
        innerWithSi["si"] = si
        let innerData = try JSONSerialization.data(withJSONObject: innerWithSi)
        let rsaEnc = try rsaEncrypt(pem: pub, data: Data(secretStr.utf8))
        let aesEnc = try aesCBC(op: CCOperation(kCCEncrypt), key: aesKey, iv: iv, data: innerData)
        return [
            "req": "encrypted",
            "iv": iv.base64EncodedString(),
            "rsa": rsaEnc.base64EncodedString(),
            "aes": aesEnc.base64EncodedString(),
        ]
    }

    private func decryptSecret(_ b64: String) throws -> Data {
        guard let data = Data(base64Encoded: b64) else { throw FnErr.crypto }
        return try aesCBC(op: CCOperation(kCCDecrypt), key: aesKey, iv: iv, data: data)
    }

    private func rsaEncrypt(pem: String, data: Data) throws -> Data {
        let b64 = pem
            .replacingOccurrences(of: "-----BEGIN PUBLIC KEY-----", with: "")
            .replacingOccurrences(of: "-----END PUBLIC KEY-----", with: "")
            .replacingOccurrences(of: "\n", with: "")
            .replacingOccurrences(of: "\r", with: "")
        guard let der = Data(base64Encoded: b64) else { throw FnErr.badPub }
        let attrs: [CFString: Any] = [
            kSecAttrKeyType: kSecAttrKeyTypeRSA,
            kSecAttrKeyClass: kSecAttrKeyClassPublic,
        ]
        guard let key = SecKeyCreateWithData(der as CFData, attrs as CFDictionary, nil) else {
            throw FnErr.badPub
        }
        guard let enc = SecKeyCreateEncryptedData(key, .rsaEncryptionPKCS1, data as CFData, nil) else {
            throw FnErr.rsa
        }
        return enc as Data
    }

    private func aesCBC(op: CCOperation, key: Data, iv: Data, data: Data) throws -> Data {
        var out = Data(count: data.count + kCCBlockSizeAES128)
        var outLen: size_t = 0
        let outCount = out.count
        let status = out.withUnsafeMutableBytes { ob in
            data.withUnsafeBytes { db in
                key.withUnsafeBytes { kb in
                    iv.withUnsafeBytes { ib in
                        CCCrypt(op, CCAlgorithm(kCCAlgorithmAES), CCOptions(kCCOptionPKCS7Padding),
                                kb.baseAddress, key.count, ib.baseAddress,
                                db.baseAddress, data.count, ob.baseAddress, outCount, &outLen)
                    }
                }
            }
        }
        guard status == kCCSuccess else { throw FnErr.crypto }
        return out.prefix(outLen)
    }

    private func hmacBase64(key: Data, data: Data) -> String {
        let mac = HMAC<SHA256>.authenticationCode(for: data, using: SymmetricKey(data: key))
        return Data(mac).base64EncodedString()
    }

    // ---------- 工具 ----------

    private func newId() -> String {
        let s = q.sync { () -> Int in self.seq += 1; return self.seq }
        let t = String(Int64(Date().timeIntervalSince1970 * 1000), radix: 16)
        let r = String(Int.random(in: 0..<1_000_000), radix: 16)
        return t + String(s, radix: 16) + r
    }

    private func makeDid() -> String {
        let t = String(Int64(Date().timeIntervalSince1970 * 1000), radix: 36)
        return t + "-" + rand36(13) + "-" + rand36(13)
    }

    private func rand36(_ n: Int) -> String {
        let cs = "0123456789abcdefghijklmnopqrstuvwxyz"
        var s = ""
        for _ in 0..<n { s.append(cs.randomElement()!) }
        return s
    }
}
