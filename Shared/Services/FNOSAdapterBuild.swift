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
    static let version = "v141"

    /// 本版主要变更摘要
    static let changes = "v141:修Hero轮播切换失效。根因=v139给按钮组HStack加的.focusSection()——焦点在focusSection内时引擎接管组内导航,不再向按钮投递onMoveCommand,play左翻/detail右翻失效。摘除该修饰符恢复v133语境(翻页正常),下键入墙由ScrollView原生几何处理不受影响。其余零改动。"
}
