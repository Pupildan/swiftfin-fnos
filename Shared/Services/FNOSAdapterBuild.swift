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
    static let version = "v153"

    /// 本版主要变更摘要
    static let changes = "v153:操作逻辑完全还原v100(用户明确要求)。HeroView=v98/v100原文件字节级还原(focusEffectDisabled+左右滑翻页+.down单次下键→onDownToShelf滚墙顶);MainView外壳还原v100语义:单次下键进海报墙(scrollTo墙顶+450ms落焦点)、onChange仅预取(守卫/滚顶/诊断全部移除)、focusSection回整墙、banner无ignoresSafeArea。撤销v144-v152全部实验手势(.up翻页/双击下键/守卫/scrollDisabled/DragGesture/UIPanDetector)。保留v140架构(Hero随滚动滑出)+v100后新功能(豆瓣/TMDB/番剧行、入库、刷新)。"
}
