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
    static let version = "v138"

    /// 本版主要变更摘要
    static let changes = "v138:官方推荐UIFocusGuide隔离带。在Hero与海报墙之间插入20pt高的UIFocusGuide(UIViewRepresentable包装,自身永不可聚焦不参与触摸),拦截Hero区向下焦点搜索并转交给海报墙(空间就近=继续播放首卡)。视图高度与结构零改动。同时移除v132 guard弹回逻辑(与Guide转交互抢焦点,Guide为原生替代)。不加折叠不加onMoveCommand拦截。"
}
