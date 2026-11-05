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
    static let version = "v134"

    /// 本版主要变更摘要
    static let changes = "v134:1)修首页焦点跳页——hero banner加.focusSection()建立焦点边界,防止clickpad触摸被Focus Engine当成swipe推到海报墙。2)豆瓣详情hero加.focusable()——修下键无法从hero移到内容区(根因:hero无focusable元素,Focus Engine找不到起点)。3)TMDB详情hero加.focusable()——同上,修下方cast/trailer/similar区块无法通过焦点到达。"
}
