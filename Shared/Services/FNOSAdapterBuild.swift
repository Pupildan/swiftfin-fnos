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
    static let version = "v148"

    /// 本版主要变更摘要
    static let changes = "v148:Hero区一比一复刻v98真机验证版(git checkout 1672097原文件,603行字节级还原)。三按钮.focusEffectDisabled()+onMoveCommand(.down→onDownToShelf显式滚墙顶,play左翻/detail右翻,无节流无v131按钮间导航);MainView恢复onDownToShelf传参(scrollTo墙顶+450ms落焦点)。外层保持v140架构(Hero在ScrollView内随滚动滑出)+v143半屏修复。移除v144-v147全部实验代码(scrollDisabled/容器级onMoveCommand/DragGesture/UIPanGestureRecognizer)。"
}
