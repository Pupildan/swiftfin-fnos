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
    static let version = "v137"

    /// 本版主要变更摘要
    static let changes = "v137:首页焦点复盘方案(一次到位)。1)Hero与海报墙物理分家——Hero固定62%高度不再进ScrollView,海报墙独立ScrollView+.focusSection(),根除共用ScrollView吃触控板事件导致的触摸跳页(也根除v136墙被挤成0高的bug)。2)不折叠不guard不拦截——纯静态布局,Focus Engine经focusSection自然双向路由(下键入墙立即落首卡无延迟,上键回Hero)。3)移除shelfFocusBypass/heroFocusResetToken/focusResetToken全部复杂状态。"
}
