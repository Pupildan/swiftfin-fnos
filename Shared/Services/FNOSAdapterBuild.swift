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
    static let version = "v157"

    /// 本版主要变更摘要
    static let changes = "v157:修正排查器标签错位——位掩码1=豆瓣/2=TMDB/4=番剧,此前掩码6(实隐豆瓣)误标「隐藏番剧」、掩码3(实隐番剧)误标「隐藏豆瓣」。行隐藏本身是生效的,只是标签对调导致归因混乱。修正后:全部显示→隐藏豆瓣→隐藏TMDB→隐藏番剧→仅海报墙。"
}
