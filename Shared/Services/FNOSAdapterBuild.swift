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
    static let version = "v142"

    /// 本版主要变更摘要
    static let changes = "v142:修Hero轮播切换(真根因)。diff证明v141按钮代码≡v133,而v122翻页正常——唯一差异=v133误删的.focusEffectDisabled()。该修饰符在场时方向输入回落到按钮onMoveCommand(左滑翻页),删除后引擎自行处理方向输入、onMoveCommand不再投递。三个按钮恢复此修饰符(v122验证配置,仅屏蔽系统焦点视觉,自绘视觉与焦点移动不受影响)。v141的focusSection摘除保留(无意义但无害)。"
}
