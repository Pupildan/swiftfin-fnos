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
    static let version = "v132"

    /// 本版主要变更摘要
    static let changes = "v132:1)修豆瓣演员/评论不显示——frodoCelebrities/frodoReviews路径双重/api/v2前缀导致404,已修正。2)豆瓣详情简介搬进hero(与TMDB对齐),contentSection不再重复。3)celebrities接口失败时用frodoDetail.castNames文字降级。4)修首页焦点跳页——新增shelf-side guard:非onDownToShelf路径进入海报墙时硬弹回Hero按钮(focusResetToken机制),右键/滑动焦点逃逸彻底拦截。"
}
