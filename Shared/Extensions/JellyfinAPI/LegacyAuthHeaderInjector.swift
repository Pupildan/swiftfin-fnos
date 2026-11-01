//
// Swiftfin is subject to the terms of the Mozilla Public
// License, v2.0. If a copy of the MPL was not distributed with this
// file, you can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2026 Jellyfin & Jellyfin Contributors
//

import Foundation
import Get
import JellyfinAPI

/// 飞牛影视（8005 端口 Jellyfin 兼容层）只识别旧式 `X-Emby-Authorization`
/// 鉴权头（Infuse 等客户端使用的形式），而 jellyfin-sdk-swift 注入的是
/// Jellyfin 10.9+ 才支持的新式 `Authorization: MediaBrowser ...` 头。
/// 兼容层读不到鉴权串时，`POST /Users/AuthenticateByName` 返回 400。
///
/// 该 delegate 在 SDK 注入完成后被调用（PassthroughAPIClientDelegate 先注入
/// `Authorization`，再转发到本 delegate），把同一鉴权串复制到
/// `X-Emby-Authorization`，并将字段值转为带引号形式（与 Infuse 一致）。
/// 对标准 Jellyfin 服务器无害：多一个等值头不改变语义。
final class LegacyAuthHeaderInjector: APIClientDelegate, @unchecked Sendable {

    func client(_ client: APIClient, willSendRequest request: inout URLRequest) async throws {
        guard let authorization = request.value(forHTTPHeaderField: "Authorization"),
              authorization.hasPrefix("MediaBrowser"),
              request.value(forHTTPHeaderField: "X-Emby-Authorization") == nil
        else { return }

        request.setValue(quoted(authorization), forHTTPHeaderField: "X-Emby-Authorization")
    }

    /// `MediaBrowser Client=x, Device=y, Token=z`
    ///   -> `MediaBrowser Client="x", Device="y", Token="z"`
    private func quoted(_ authorization: String) -> String {
        guard let schemeEnd = authorization.range(of: "MediaBrowser ") else {
            return authorization
        }

        let scheme = authorization[..<schemeEnd.upperBound]
        let fields = authorization[schemeEnd.upperBound...]
            .split(separator: ",")
            .map { field -> String in
                let parts = field.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
                guard parts.count == 2 else {
                    return field.trimmingCharacters(in: .whitespaces)
                }
                let key = parts[0].trimmingCharacters(in: .whitespaces)
                let value = parts[1].trimmingCharacters(in: .whitespaces)
                return "\(key)=\"\(value)\""
            }

        return scheme + fields.joined(separator: ", ")
    }
}
