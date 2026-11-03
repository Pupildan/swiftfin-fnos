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
    static let version = "v77"

    /// 本版主要变更摘要
    static let changes = "详情过渡动画实装 v77（方案 B+ 核心缩放）：海报墙点击→起跳横图(matched A→B)从卡片位单次弹簧放大到全屏，落地交叉淡入真实详情 Hero（终点=全屏，方案甲零跳位）；压暗背景 0.35 + 延迟信息层；主页过渡期整体 disabled 防焦点泄漏；落地/关闭后焦点显式还给来源卡。同行推出(行副本 3.0)留待 v78。"
}
