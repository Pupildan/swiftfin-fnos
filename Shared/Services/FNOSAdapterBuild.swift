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
    static let version = "v114"

    /// 本版主要变更摘要
    static let changes = "v114:修复TMDB热门推荐行消失。根因:fetchTMDBIfNeeded用tmdbDate!=today守卫,但tmdbItems是@State每次启动重置为空,同一天第二次打开App时tmdbDate匹配today直接return不抓取,tmdbItems留空行消失。改为guard tmdbItems.isEmpty,每次启动总会抓取。"
}
