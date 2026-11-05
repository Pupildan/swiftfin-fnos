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
    static let version = "v139"

    /// 本版主要变更摘要
    static let changes = "v139:Apple TV+标准架构重构(外层骨架)。1)ZStack叠层——底层Hero视觉原样保留(全屏背景+轮播+智能预告+按钮组内部零改动),顶层透明垂直ScrollView(顶部65%屏幕高度占位露出Hero,其后依次排列继续播放+媒体库各行)。2)Hero按钮组容器加.focusSection(),继续播放横向列表加.focusSection()。3)删除UIFocusGuideBand,删除onMoveCommand的.down分支与onDownToShelf回调,完全依赖UIKit焦点引擎物理几何计算——Hero按上键原生滚动让页面自动上移。4)不折叠不拦截不动态改高度。"
}
