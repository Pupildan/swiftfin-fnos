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
    static let version = "v44"

    /// 本版主要变更摘要
    static let changes = "修复剧集详情页选集不显示(分集双端点兜底,失败不再阻断整页)；演员阵容移到选集下方；详情页背景取色+高斯模糊+液态流动；进入详情页加缩放淡入过渡；海报墙缓存命中不再闪转圈"
}
