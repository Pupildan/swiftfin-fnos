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
    static let version = "v55"

    /// 本版主要变更摘要
    static let changes = "色彩识别改读解码轨实测(飞牛 VideoRangeType 常误报 SDR)；实测为杜比视界时运行时把显示模式请求改回 HDR10，避免电视按 DV 解普通 PQ 画面导致紫绿"
}
