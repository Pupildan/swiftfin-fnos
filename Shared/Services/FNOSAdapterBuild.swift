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
    static let version = "v74"

    /// 本版主要变更摘要
    static let changes = "过渡动画 Demo v3：改用真实电影数据（真海报卡片 + 焦点预取 1920 横图，起跳即横图对齐参考）；同行海报参与进出场（当前行以焦点卡为锚点整体放大，其他卡推出屏幕外，返回反向缩回）；修返回失效（关闭后焦点显式还给来源卡片 + 详情层焦点多次兜底）"
}
