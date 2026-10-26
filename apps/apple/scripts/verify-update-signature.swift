// 用 App 里写死的公钥（Info.plist 的 SUPublicEDKey）核对更新包的 EdDSA 签名（package-mac-app.sh 调用）。
// sign_update --verify 只能用私钥推出的公钥验，查不出「仓库密钥和 App 里的公钥不是一对」——那样签出来的更新包
// 所有客户端都会拒收。Sparkle 用的是标准 Ed25519，CryptoKit 的 Curve25519.Signing 就是它。
//   swift verify-update-signature.swift <SUPublicEDKey> <签名 base64> <文件>
import CryptoKit
import Foundation

let arguments = CommandLine.arguments
guard arguments.count == 4,
      let key = Data(base64Encoded: arguments[1]),
      let signature = Data(base64Encoded: arguments[2]),
      let data = FileManager.default.contents(atPath: arguments[3]) else {
    FileHandle.standardError.write(Data("用法：verify-update-signature.swift <公钥> <签名> <文件>\n".utf8))  // i18n-ignore: developer tool output
    exit(2)
}
guard let publicKey = try? Curve25519.Signing.PublicKey(rawRepresentation: key),
      publicKey.isValidSignature(signature, for: data) else {
    FileHandle.standardError.write(Data("签名和 App 里的公钥对不上\n".utf8))  // i18n-ignore: developer tool output
    exit(1)
}
