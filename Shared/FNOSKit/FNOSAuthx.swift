import Foundation
import CryptoKit

/// 飞牛影视 API 请求签名器（authx 请求头）。
///
/// 算法逆向自官方客户端，参考实现：
/// - `_reference/fnos_tv_danmu/.../api/FnAuthUtils.java`（常量 + 算法）
/// - `_reference/fnos_tv_danmu/.../api/AuthInterceptor.java`（注入方式）
///
/// 规则：
/// 1. nonce   —— 6 位随机数字
/// 2. ts      —— 毫秒时间戳
/// 3. payload —— POST：请求体 JSON 原文；GET：query 原文；无参数：空字符串
///               （即对"服务器实际收到的那一串"做 md5）
/// 4. signStr = apiKey + "_" + path + "_" + nonce + "_" + ts + "_" + md5(payload) + "_" + apiSecret
/// 5. Authx:  "nonce=<nonce>&timestamp=<ts>&sign=<md5(signStr)>"
public enum FNOSAuthx {

    /// 为一次请求生成 Authx 头的值。
    /// - Parameters:
    ///   - path: 完整请求路径（含 `/v` 前缀，如 `/v/api/v1/login`）
    ///   - payload: 参与签名的原文（POST 传请求体字符串，GET 传 query 字符串，无则传 nil）
    public static func headerValue(path: String, payload: String?) -> String {
        let nonce = String(Int.random(in: 100_000...999_999))
        let ts = String(Int64(Date().timeIntervalSince1970 * 1000))
        let payloadHash = md5(payload ?? "")

        let signStr = [
            FNOSConfig.apiKey,
            path,
            nonce,
            ts,
            payloadHash,
            FNOSConfig.apiSecret,
        ].joined(separator: "_")

        return "nonce=\(nonce)&timestamp=\(ts)&sign=\(md5(signStr))"
    }

    /// 小写 32 位 MD5（与官方客户端一致）
    public static func md5(_ string: String) -> String {
        Insecure.MD5.hash(data: Data(string.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }
}
