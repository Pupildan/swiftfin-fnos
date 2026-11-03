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
    static let version = "v63"

    /// 本版主要变更摘要
    static let changes = "详情过渡重做（参考 Apple TV 版式）：竖版海报按原比例长成整屏高、同图模糊铺底填满两侧，主页同步压暗；弹簧缓动 0.5s → 详情横图 0.45s 淡入覆盖 → 1s 无 UI → 信息层上移淡入；返回反向缩回卡片"
}
