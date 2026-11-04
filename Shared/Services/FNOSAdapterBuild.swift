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
    static let version = "v117"

    /// 本版主要变更摘要
    static let changes = "v117:热门番剧数据源改近期注目(HTML解析+800px封面,官方API无此端点)+TMDB/Bangumi每日持久缓存(AppStorage JSON,同日重启零请求,跨日刷新,失败退缓存)+海报文字间距6→16(焦点动画不再压字)+两个详情页infoSection加focusable(下键可滚动)。"
}
