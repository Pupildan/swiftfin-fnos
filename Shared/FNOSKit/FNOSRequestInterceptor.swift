import Foundation

/// 请求拦截器：负责为每个出站请求注入飞牛服务端要求的全部请求头。
///
/// 对标 fnos_tv_danmu 的 `AuthInterceptor.java`（OkHttp Interceptor）：
/// - `Authx`        —— 每次请求实时计算签名（见 `FNOSAuthx`）
/// - `Authorization`—— 登录返回的 token（原样携带，**没有** Bearer 前缀）
/// - `Cookie: mode=relay`
/// - `x-trim-client` / `x-trim-client-version`
/// - `Referer`      —— 仅 play/record（进度上报）需要
///
/// 签名算法来源（若官方升级导致鉴权失败，从这里重新提取）：
/// 1. `_reference/fnos_tv_danmu/.../api/FnAuthUtils.java` —— API_KEY / API_SECRET 常量原文与算法
/// 2. `_reference/fnos_tv_danmu/.../api/AuthInterceptor.java` —— 头注入与 GET 用 query 参与签名的规则
/// 3. 官方网页端：查看网页源码，找到第二个 .js 文件，
///    搜索 `"].join("_")` 左边的字符串 = secret（API_SECRET）；
///    搜索 `${Ld}/sys/progressThumb` 右边的字符串 = api_key
public final class FNOSRequestInterceptor {

    public static let shared = FNOSRequestInterceptor()

    /// 当前登录 token（线程安全）
    private let lock = NSLock()
    private var _token: String?

    public var token: String? {
        get { lock.lock(); defer { lock.unlock() }; return _token }
        set { lock.lock(); defer { lock.unlock() }; _token = newValue }
    }

    /// 进度上报接口需要的 Referer（一般为服务器首页地址）
    public var referer: String?

    public init() {}

    /// 为一次请求生成全部请求头。
    ///
    /// - Parameters:
    ///   - method: HTTP 方法（大小写不敏感）
    ///   - path:   完整路径（含 `/v` 前缀，如 `/v/api/v1/item/list`）
    ///   - query:  GET 的 query 原文（如 `q=海贼`），无则 nil
    ///   - body:   POST 的请求体 Data（需与实际发送的完全一致）
    public func headers(method: String, path: String, query: String?, body: Data?) -> [String: String] {
        // 签名原文：POST 用请求体原文，GET 用 query 原文，都没有则空串
        let signPayload: String
        if method.uppercased() == "GET" {
            signPayload = query ?? ""
        } else {
            signPayload = body.flatMap { String(data: $0, encoding: .utf8) } ?? ""
        }

        var headers: [String: String] = [
            "Authx": FNOSAuthx.headerValue(path: path, payload: signPayload),
            "Content-Type": "application/json",
            "Accept": "application/json",
            "Cookie": "mode=relay",
            "x-trim-client": "web",
            "x-trim-client-version": "608",
        ]

        // ★ Authorization 头注入点：token 原样携带（无 Bearer 前缀）
        if let token, !token.isEmpty {
            headers["Authorization"] = token
        }

        if let referer, !referer.isEmpty,
           path.contains("play/record") {
            headers["Referer"] = referer
        }

        return headers
    }

    /// 为播放器（AVURLAsset / VLCKit）生成媒体直链所需的请求头。
    /// 签名不包含 Range，因此一次生成的头对整个播放会话（含 Range 分片请求）均有效。
    public func mediaHeaders(for url: URL) -> [String: String] {
        var headers = headers(method: "GET", path: url.path, query: url.query, body: nil)
        headers.removeValue(forKey: "Content-Type")
        headers.removeValue(forKey: "Accept")
        return headers
    }
}
