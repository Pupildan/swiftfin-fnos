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
    static let version = "v140"

    /// 本版主要变更摘要
    static let changes = "v140:修Hero死背景。1)拆除ZStack叠层——Hero整体(全屏背景+渐变遮罩+Logo+简介+按钮组)作为ScrollView第一项,按下键时随ScrollView一起平滑滑出屏幕,卡片自然推上(ATV+内容跟随)。2)Hero高度100%屏高+ignoresSafeArea铺满,无占位无重叠。3)Hero信息区整体上移(bottom 72→190)对齐ATV+参考图。4)焦点路由与.focusSection()零改动。"
}
