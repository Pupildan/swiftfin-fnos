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
    static let version = "v133"

    /// 本版主要变更摘要
    static let changes = "v133:1)修首页焦点——移除Hero按钮.focusEffectDisabled()(根因:该修饰符导致UIKit Focus Engine不认按钮为选中目标,select按下不触发action反而被当成焦点移动推到海报墙)。2)豆瓣详情contentSection加.focusSection()——修下键无法从hero移到内容区。3)TMDB详情新增castAvatarSection(演员头像行)放到hero下方——infoSection里的cast部分从未加入body导致永远不渲染。4)TMDB详情各区块补.focusSection()。"
}
