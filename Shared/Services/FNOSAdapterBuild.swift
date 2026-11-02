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
    static let version = "v57"

    /// 本版主要变更摘要
    static let changes = "mpv 引擎补齐功能：续播、弹幕、换集条、进度条、快进快退、诊断面板；字幕改走文本拦截用系统字体渲染（修乱码）；解码显式 VideoToolbox；设置页改为自绘列表，两侧留白且去掉系统灰焦点板"
}
