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
    static let version = "v83"

    /// 本版主要变更摘要
    static let changes = "v83 修「进入时同行不参与动画」：正向飞行层在 spring 事务内插入被 SwiftUI 默认套 .opacity 过渡，整层（含行副本）从 0 淡入，副本未显形即被放大的横图盖住；反向在 nil 动画事务内插入无过渡故正常（不对称现象的根源）。飞行层显式 .transition(.identity) 插入帧即全量渲染，matched 几何插值不受影响；撤去每次起跳的 ✓ 诊断 toast（失败路径 ⚠️ 保留）。"
}
