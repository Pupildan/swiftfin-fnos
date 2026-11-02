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
    static let version = "v54"

    /// 本版主要变更摘要
    static let changes = "杜比视界/HDR 处理：识别 VideoRangeType，DoVi 内容改按 HDR10 请求显示模式（避免电视按 DV 解普通 PQ 画面导致紫绿）；控制条显示格式标记；设置可开关"
}
