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
    static let version = "v67"

    /// 本版主要变更摘要
    static let changes = "详情页过渡改两段式：海报放大过程中逐渐模糊变暗（消散感），放大到 60% 时详情页清晰图整屏淡入并与模糊海报重叠，随后海报消散、清晰图静置 0.45s 后信息层淡入；全程 0.4s 无停顿，消除卡顿与闪切"
}
