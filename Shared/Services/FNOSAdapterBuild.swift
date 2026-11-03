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
    static let version = "v71"

    /// 本版主要变更摘要
    static let changes = "回滚详情页过渡动画：恢复为 v61 的 fullScreenCover 直接全屏弹出详情页（无任何过渡动画）。过渡动画（v62~v70）全部废弃，因 tvOS 官方不支持 .navigationTransition(.zoom)（系统回退 automatic），手搓方案又卡顿割裂"
}
