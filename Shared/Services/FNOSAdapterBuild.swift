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
    static let version = "v124"

    /// 本版主要变更摘要
    static let changes = "v124:修正——把加错到首页的内容区(logo/主演/预告/花絮/相关)从首页撤除、原样搬进热门影视详情页(点击海报进入)。首页布局恢复 v122(仅保留海报标题自动换行+Hero取色高斯模糊背景+Hero风格)。详情页新增居中logo+花絮·幕后行(拉流播放),主演/预告/相关已在。"
}
