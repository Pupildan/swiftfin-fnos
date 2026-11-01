//
// Swiftfin is subject to the terms of the Mozilla Public
// License, v2.0. If a copy of the MPL was not distributed with this
// file, you can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2026 Jellyfin & Jellyfin Contributors
//

import Foundation

extension URLSessionConfiguration {

    /// A session configuration object built upon the default
    /// configuration with values for Swiftfin.
    static let swiftfin: URLSessionConfiguration = {
        let configuration = URLSessionConfiguration.default
            .mutating(\.timeoutIntervalForRequest, with: 20)

        // 飞牛影视 8005 兼容层适配（鉴权头/参数改写/未实现端点兜底）
        var protocolClasses = configuration.protocolClasses ?? []
        protocolClasses.insert(FnOSCompatURLProtocol.self, at: 0)
        configuration.protocolClasses = protocolClasses

        return configuration
    }()
}
