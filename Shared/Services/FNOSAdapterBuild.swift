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
    static let version = "v154"

    /// 本版主要变更摘要
    static let changes = "v154:轻触跳焦对照实验。静态排查结论:v98→HEAD的MainView结构/焦点API与v98逐字一致(用户怀疑的focusSection误加/间距缩小均被diff否定),唯一差异=内容层(豆瓣/TMDB/番剧三行+异步拉取+v110卡片渲染/v112 Equatable/v123标题换行/v122排序刷新)。本版加设置开关「经典首页模式v98」:开=隐藏三行+停用其异步拉取(首页动态结构=纯v98),关=现状。真机即时A/B定位根因,不用反复出包。"
}
