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
    static let version = "v194"

    /// 本版主要变更摘要
    static let changes = "v194:①KS/MPV 共用的弹幕无极滑块步进加大(字号2/不透明度0.05/速度0.1/区域0.05 每步)+连按连滑加速(0.2s内翻倍最多×4)——两个内核同步生效;②首页新增搜索功能(设置按钮旁放大镜):输入片名/剧名→媒体库优先匹配(媒体库结果带✓标)→TMDB 兜底(可入库),结果点击直接进对应详情页(库内详情/TMDB详情含入库按钮),全部官方液态玻璃风格;③mpv色彩(tone-mapping bt.2390+色域per-channel)。"
}
