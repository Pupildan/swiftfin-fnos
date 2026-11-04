//
// Swiftfin is subject to the terms of the Mozilla Public
// License, v2.0. If a copy of the MPL was not distributed with this
// file, can be obtained one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2026 Jellyfin & Jellyfin Contributors
//

import Foundation

/// 飞牛影视（fnOS）适配版本标识。
///
/// 每次交付新 ipa 前递增 `version`，用户可在
/// 「设置 → 关于本应用」与「设置 → 高级」核对更新是否生效。
enum FNOSAdapterBuild {

    /// 适配版本号（递增）
    static let version = "v111"

    /// 本版主要变更摘要
    static let changes = "v111:新增热门推荐功能(Phase 1)。TMDB API客户端+数据模型+首页热门推荐海报墙行+每日自动刷新+设置面板TMDB API Key输入框。API Key由用户在设置里自行填写(开源友好)。"
}
