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
    static let version = "v135"

    /// 本版主要变更摘要
    static let changes = "v135:1)物理隔离ScrollView(方案B)——Hero不再和海报墙共用ScrollView,Hero固定在顶部独立于下方ScrollView,彻底消除触控板微小滑动被ScrollView吃掉的问题。2)Hero折叠/展开机制——按下键时Hero折叠(height→0),海报墙填满屏幕;按上键时Hero展开恢复。3)触控降敏(方案C)——heroButtonLabel加.contentShape(Rectangle())严格限制点击边界+动画时长0.16s→0.2s easeInOut。"
}
