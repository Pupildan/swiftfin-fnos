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
    static let version = "v56"

    /// 本版主要变更摘要
    static let changes = "新增 mpv 引擎（MPVUI/gpu-next，libplacebo 做 DoVi P5 色彩转换），设置里可切换；mpv 走飞牛原生 media/range 直链（仅需 Authorization 头），实验阶段只提供画面/进度/快进快退"
}
