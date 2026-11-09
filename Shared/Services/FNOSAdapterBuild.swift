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
    static let version = "v202"

    /// 本版主要变更摘要
    static let changes = "v202:MPV 弹幕颜色还原修复(用户实测白色弹幕变灰、颜色不准确)——根因=MPVUI 的 HDRPolicy 默认 .automatic,杜比视界内容以 HDR 直出(Metal 层 EDR),电视切 HDR 显示模式后系统把 App 的 SDR 浮层(弹幕/字幕/控制条)整体压暗,纯白变灰白;修复=hdrPolicy 改 .disabled,Metal 层强制 SDR,mpv 用 bt.2390 把 HDR 色调映射到 SDR,显示模式留在 SDR,弹幕/字幕/控制条恢复真实白色。代价:mpv 路径不再 HDR 直出(亮度峰值降至 SDR),色彩准确性优先(与 v192 用户选型一致)。同含 v201 屏保双保险修复。"
}
