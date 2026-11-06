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
    static let version = "v144"

    /// 本版主要变更摘要
    static let changes = "v144:修Hero轮播切换(日志实锤根因)。诊断日志证实:焦点在Hero按钮上时,触摸板水平滑动全部被垂直ScrollView分类为.down(onMoveCommand .left/.right从未触发)。修法=焦点在Hero时scrollDisabled(true)禁用ScrollView滚动,水平滑动不再被吃、正确分类为.left/.right触发翻页。焦点移到海报墙后scrollDisabled自动解除恢复滚动。半屏修复(v143)保留。"
}
