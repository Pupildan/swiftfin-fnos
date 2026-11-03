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
    static let version = "v75"

    /// 本版主要变更摘要
    static let changes = "海报 → 详情过渡动画正式实装（Demo v3 真机验证机制）：点卡片后起跳层（焦点预取的 1920 详情横图）从卡片位置单段连续动画放大到全屏，同帧无缝切详情页；当前行以焦点卡为锚点整体放大、其他卡推出屏幕外；返回反向缩回并还焦点。海报卡焦点玻璃效果改用系统 .card 样式；删除设置里的过渡 Demo 入口与代码；删除详情页临时诊断信息"
}
