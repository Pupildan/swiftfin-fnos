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
    static let version = "v126"

    /// 本版主要变更摘要
    static let changes = "v126:首页「热门影视」前新增「豆瓣热门」行(布局同热门影视/番剧)。豆瓣无公开API,走网页JSON端点抓取60条=热门电影20+电视剧20+综艺20,每日缓存。点海报进轻量详情页(大海报+评分+类型+集数;豆瓣条目页反爬302抓不了,故用列表数据)。已实现功能未改动。"
}
