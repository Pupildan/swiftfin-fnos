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
    static let version = "v128"

    /// 本版主要变更摘要
    static let changes = "v128:修豆瓣海报不显示——豆瓣CDN防盗链(无Referer返回418空图),海报加载加Referer:movie.douban.com,海报墙+详情页大海报均修复。豆瓣热门行/其它功能未动。"
}
