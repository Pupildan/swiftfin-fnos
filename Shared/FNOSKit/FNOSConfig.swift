import Foundation
import CryptoKit

/// 飞牛影视服务端连接配置。
///
/// 密钥常量来自官方 Web/TV 客户端的逆向产物，与 fnos_tv_danmu 的
/// `FnAuthUtils.java` 保持一致。若官方升级后签名失效，请按 README
/// 中的「签名算法来源」一节重新提取。
public enum FNOSConfig {

    /// 默认端口
    public static let defaultPort: Int = 5666

    /// 登录时的应用标识（官方 Web 端固定值）
    public static let appName: String = "trimemedia-web"

    /// 签名密钥（对应网页前端源码中的 secret_string）
    public static let apiKey: String = "NDzZTVxnRKP8Z0jXg1VAMonaG8akvh"

    /// 签名密钥（对应 fnos_tv_danmu 中的 API_SECRET）
    public static let apiSecret: String = "16CCEB3D-AB42-077D-36A1-F355324E4237"

    /// 所有 API 的公共前缀
    public static let apiPrefix: String = "/v/api/v1"

    /// 图片接口前缀（拼接 poster 相对路径后使用）
    public static let imagePrefix: String = "/v/api/v1/sys/img"

    /// 由主机地址构造服务端 URL（容忍用户输入 "192.168.1.10" / ":5666" 等格式）
    public static func serverURL(fromHost host: String) -> URL? {
        var raw = host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return nil }
        if !raw.hasPrefix("http://") && !raw.hasPrefix("https://") {
            raw = "http://" + raw
        }
        // 剥离 scheme 后再查端口冒号（"http://" 中的冒号不算数）
        let afterScheme: Substring
        if raw.hasPrefix("https://") {
            afterScheme = raw.dropFirst(8)
        } else if raw.hasPrefix("http://") {
            afterScheme = raw.dropFirst(7)
        } else {
            afterScheme = raw[...]
        }
        if !afterScheme.contains(":") {
            raw += ":\(defaultPort)"
        }
        if !raw.hasSuffix("/") { raw += "/" }
        return URL(string: raw)
    }
}
