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
    static let version = "v162"

    /// 本版主要变更摘要
    static let changes = "v162:修「按下键三行不显示」(实机实证:引擎的下键移动是静默的——不投递.down命令,onDownToShelf不触发,v161的挂载触发单点失效)。修复:挂载兜底移入onChange进入分支(无论命令投递还是静默移动,首次进入海报墙即挂载+滚墙顶+焦点纠正到首卡)。附带:卸载守卫扩展到播放器/选集面板(此前播放期间推荐行被误卸载)。"
}
