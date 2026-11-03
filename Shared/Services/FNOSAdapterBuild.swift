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
    static let version = "v68"

    /// 本版主要变更摘要
    static let changes = "详情页过渡改用系统原生 zoom（navigationTransition(.zoom)+matchedTransitionSource）：删掉全部手搓飞行层/分段动画，由 tvOS 18+ 系统处理卡片放大、背景压暗、连续缓动与反向缩回，彻底消除卡顿与割裂"
}
