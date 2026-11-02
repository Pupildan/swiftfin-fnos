//
// FNOSAuthStore.swift
// 飞牛影视（fnOS 8005 兼容层）登录凭据存储 —— 极简原生实现。
//
// 只存三样东西：服务器地址、访问令牌、用户 ID。
// 用 UserDefaults 明文存储（纯局域网应用，此前 Swiftfin 方案同样明文落库）。
//

import Foundation
import SwiftUI

struct FNOSCredentials: Codable, Equatable {
    var serverURL: URL
    var token: String
    var userID: String
    var userName: String
    /// 飞牛**原生** API token（`/v/api/v1/` 用；与兼容层的 AccessToken 不是同一套）。
    /// 演员阵容、精确时长只能从原生接口取到，所以登录时顺手换一个存下来。
    var nativeToken: String? = nil
}

@MainActor
final class FNOSAuthStore: ObservableObject {

    static let shared = FNOSAuthStore()

    private static let storageKey = "fnos.credentials.v1"

    @Published private(set) var credentials: FNOSCredentials?

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.storageKey) {
            do {
                credentials = try JSONDecoder().decode(FNOSCredentials.self, from: data)
            } catch {
                print("FNOS❗️凭据解码失败，按未登录处理: \(error)")
                credentials = nil
            }
        }
    }

    var isLoggedIn: Bool { credentials != nil }

    func save(_ credentials: FNOSCredentials) {
        self.credentials = credentials
        do {
            let data = try JSONEncoder().encode(credentials)
            defaults.set(data, forKey: Self.storageKey)
        } catch {
            print("FNOS❗️凭据编码失败: \(error)")
        }
    }

    func logout() {
        credentials = nil
        defaults.removeObject(forKey: Self.storageKey)
        print("FNOSℹ️已退出登录")
    }
}

// MARK: - 登录请求（fnOS 8005 Jellyfin 兼容层 AuthenticateByName）

enum FNOSLoginError: LocalizedError {
    case badURL
    case http(Int, String)
    case emptyToken

    var errorDescription: String? {
        switch self {
        case .badURL: return "服务器地址无效"
        case .http(let code, let raw): return "HTTP \(code): \(raw)"
        case .emptyToken: return "服务器未返回令牌"
        }
    }
}

enum FNOSAuthClient {

    struct AuthenticateResponse: Decodable {
        let AccessToken: String?
        let User: FNOSUser?
    }

    struct FNOSUser: Decodable {
        let Id: String
        let Name: String?
    }

    /// 登录：与此前 Swiftfin 登录走完全相同的兼容端点 /Users/AuthenticateByName
    static func login(serverInput: String, username: String, password: String) async throws -> FNOSCredentials {
        var trimmed = serverInput.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            throw FNOSLoginError.badURL
        }
        if !trimmed.lowercased().hasPrefix("http://") && !trimmed.lowercased().hasPrefix("https://") {
            trimmed = "http://" + trimmed
        }
        while trimmed.hasSuffix("/") {
            trimmed.removeLast()
        }
        guard let baseURL = URL(string: trimmed) else {
            throw FNOSLoginError.badURL
        }

        var request = URLRequest(url: baseURL.appendingPathComponent("Users/AuthenticateByName"))
        request.httpMethod = "POST"
        request.timeoutInterval = 15
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // fnOS 硬性要求：无 Token 的老式 X-Emby-Authorization 头
        request.setValue(
            "MediaBrowser Client=\"Swiftfin\", Device=\"AppleTV\", DeviceId=\"fnos-direct\", Version=\"1.0\"",
            forHTTPHeaderField: "X-Emby-Authorization"
        )

        let body: [String: String] = ["Username": username, "Pw": password]
        do {
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        } catch {
            print("FNOS❗️登录请求体编码失败: \(error)")
            throw error
        }

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw FNOSLoginError.badURL
        }
        guard (200..<300).contains(http.statusCode) else {
            let raw = String(data: data.prefix(200), encoding: .utf8) ?? ""
            print("FNOS❗️登录失败 HTTP \(http.statusCode): \(raw)")
            throw FNOSLoginError.http(http.statusCode, raw)
        }

        let decoded: AuthenticateResponse
        do {
            decoded = try JSONDecoder().decode(AuthenticateResponse.self, from: data)
        } catch {
            let raw = String(data: data.prefix(300), encoding: .utf8) ?? "(非文本)"
            print("FNOS❗️登录响应解析失败: \(error) 原文: \(raw)")
            throw FNOSLoginError.http(http.statusCode, raw)
        }

        guard let token = decoded.AccessToken, !token.isEmpty, let user = decoded.User else {
            throw FNOSLoginError.emptyToken
        }

        // 顺带换飞牛原生 token（失败不影响登录，只是演员/时长拿不到）
        var nativeToken: String?
        do {
            nativeToken = try await FNOSNativeClient.login(
                baseURL: baseURL, username: username, password: password
            )
        } catch {
            print("FNOS⚠️ 原生登录失败（演员/时长将不可用）: \(error.localizedDescription)")
        }

        print("FNOS✅登录成功: \(user.Name ?? "?") @ \(trimmed) 原生token=\(nativeToken == nil ? "无" : "有")")
        return FNOSCredentials(
            serverURL: baseURL,
            token: token,
            userID: user.Id,
            userName: user.Name ?? username,
            nativeToken: nativeToken
        )
    }
}
