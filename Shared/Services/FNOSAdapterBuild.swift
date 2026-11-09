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
    static let version = "v198"

    /// 本版主要变更摘要
    static let changes = "v198:搜索框灰底修复(用户第二轮实锤)——根因=v198 给输入框自绘的胶囊填充 Capsule().fill(white 0.06~0.14碾在液态玻璃面板深色底上就是一块实心灰,且v198 关了系统焦点效果focusEffectDisabled后系统不再画标准描边,只剩这块自绘灰;用户已确认要走native风格且该灰块随焦点移动;另外v197 补 recognizer.delegate=FNOSPanBridge.shared 修好了KS无极滑块触摸滑动(用户确认已解决,禁止回滚);本版=胶囊填充置Color.clear,只保留纯描边(未聚焦 0.28pt白细框/聚焦 1.0pt 3pt白粗框),输入区背景 100% 透明透出玻璃面板本身。同含v197全部:KS滑块滑动修复/搜索功能(媒体库优先→TMDB兜底→详情页入库)/屏保所有权归容器/Hero剧集解禁/字幕保护区/弹幕显示区域/MPV与KS 1:1。"
}
