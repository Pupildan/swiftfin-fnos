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
    static let version = "v64"

    /// 本版主要变更摘要
    static let changes = "详情页过渡重做：卡片位置先把内容换成详情页那张横图（1920/4K 源，放大不糊），再连同整页一起被推近到全屏（背景卡片跟着出画），全屏后详情页无接缝接管，静置 1.1 秒才淡入信息层；返回反向缩回原卡。设置里可关闭"
}
