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
    static let version = "v72"

    /// 本版主要变更摘要
    static let changes = "新增「设置 → 过渡动画 Demo（实验）」：matchedGeometryEffect 卡片放大过渡可行性验证（单次 withAnimation 几何插值 + 信息层延迟淡入）。主流程无任何改动，验证通过后再决定是否移植到海报墙"
}
