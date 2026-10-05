import CryptoKit
import Foundation

/// 推送密文（docs/design/push-payload.md）：实例端到端加密，只有登录过那台实例的这台手机解得开，
/// 推送中继和苹果只看得到密文。
///
/// 格式 `v1.<key_id>.<nonce>.<密文>`，后三段都是 base64url（无填充）：
/// - `key_id`：这个登录（服务器 + 账号）的随机标识，通知扩展靠它找到密钥；
/// - `nonce`：12 字节随机数，每条推送一个；
/// - 密文：AES-256-GCM 的密文 + 16 字节认证标签。附加认证数据是 ASCII 的 `v1.<key_id>`，
///   防止把一段密文挪到别的 `key_id` 下。
///
/// App 与通知扩展共用（PushShared/ 编进两个目标），只依赖 Foundation 与 CryptoKit。
nonisolated enum PushCrypto {
    static let version = "v1"
    /// `key_id` 是 8 字节随机数的 base64url，11 个字符
    static let keyIDByteCount = 8
    static let nonceByteCount = 12
    static let tagByteCount = 16

    enum Failure: Error, Equatable {
        /// 不是 `v1.<key_id>.<nonce>.<密文>`
        case malformed
        /// 认证失败：密钥不对、内容被改过、挪到了别的 `key_id` 下
        case authentication
    }

    /// 拆开的一段密文
    struct Envelope: Equatable, Sendable {
        var keyID: String
        var nonce: Data
        /// 密文 + 认证标签
        var sealed: Data
    }

    /// 一把新的 256 位随机密钥
    static func generateKey() -> SymmetricKey {
        SymmetricKey(size: .bits256)
    }

    /// 一个新的随机 `key_id`（不带任何语义，只用来找密钥）
    static func generateKeyID() -> String {
        // UInt8.random 用的是系统的密码学安全随机源
        Base64URL.encode(Data((0 ..< keyIDByteCount).map { _ in UInt8.random(in: .min ... .max) }))
    }

    /// 加密成 `v1.<key_id>.<nonce>.<密文>`。nonce 只有测试向量才指定，平时每条随机
    static func seal(_ plaintext: Data, key: SymmetricKey, keyID: String, nonce: AES.GCM.Nonce = AES.GCM.Nonce()) throws -> String {
        let box = try AES.GCM.seal(plaintext, using: key, nonce: nonce, authenticating: aad(keyID))
        let nonceData = nonce.withUnsafeBytes { Data($0) }
        return [version, keyID, Base64URL.encode(nonceData), Base64URL.encode(box.ciphertext + box.tag)].joined(separator: ".")
    }

    /// 解密，返回明文字节
    static func open(_ payload: String, key: SymmetricKey) throws -> Data {
        try open(parse(payload), key: key)
    }

    static func open(_ envelope: Envelope, key: SymmetricKey) throws -> Data {
        do {
            let box = try AES.GCM.SealedBox(
                nonce: AES.GCM.Nonce(data: envelope.nonce),
                ciphertext: envelope.sealed.dropLast(tagByteCount),
                tag: envelope.sealed.suffix(tagByteCount)
            )
            return try AES.GCM.open(box, using: key, authenticating: aad(envelope.keyID))
        } catch {
            throw Failure.authentication
        }
    }

    /// 只拆格式、不解密：先拿 `key_id` 去找密钥
    static func parse(_ payload: String) throws -> Envelope {
        let parts = payload.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4, parts[0] == version, !parts[1].isEmpty,
              let nonce = Base64URL.decode(parts[2]), nonce.count == nonceByteCount,
              let sealed = Base64URL.decode(parts[3]), sealed.count >= tagByteCount
        else { throw Failure.malformed }
        return Envelope(keyID: String(parts[1]), nonce: nonce, sealed: sealed)
    }

    /// 附加认证数据：ASCII 的 `v1.<key_id>`
    private static func aad(_ keyID: String) -> Data {
        Data("\(version).\(keyID)".utf8)
    }
}

nonisolated extension SymmetricKey {
    /// 密钥原始字节的 base64url（登记推送时交给实例的 `key`）
    var base64URL: String {
        withUnsafeBytes { Base64URL.encode(Data($0)) }
    }
}

/// base64url（RFC 4648 §5），不带填充：推送密文与密钥都用它
nonisolated enum Base64URL {
    static func encode(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    /// 只认 base64url 字符（不接受标准 base64 的 `+` `/` 与填充）
    static func decode(_ text: some StringProtocol) -> Data? {
        guard text.unicodeScalars.allSatisfy({ allowed.contains($0) }) else { return nil }
        var base64 = text.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        switch base64.count % 4 {
        case 0: break
        case 1: return nil
        case let remainder: base64 += String(repeating: "=", count: 4 - remainder)
        }
        return Data(base64Encoded: base64)
    }

    private static let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_")
}
