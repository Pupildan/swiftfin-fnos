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
    static let version = "v195"

    /// 本版主要变更摘要
    static let changes = "v195:①搜索输入框灰色遮盖修复(用户实测焦点在输入框上时被系统TextField默认灰底盖住)——加textFieldStyle(.plain)去掉系统底,保留自定义玻璃胶囊;②首页左上角设置/搜索按钮位置对调(设置在左、搜索在右)。同包含v194全部内容:滑块步进加大+连按加速(KS/MPV同步)+首页搜索(媒体库优先→TMDB兜底→详情页/入库)+mpv色彩bt.2390。"
}
