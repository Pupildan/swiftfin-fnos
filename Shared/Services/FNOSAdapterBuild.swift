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
    static let version = "v130"

    /// 本版主要变更摘要
    static let changes = "v130:1)修弹幕左右抖动——sync()小漂移改渐进校正(每次纠15%漂移,不再硬重置anchor),KS轻微抖+mpv原地抖后重载均改善。2)豆瓣海报高清(s_ratio→m_ratio_poster)。3)豆瓣详情页重构成热门影视/番剧同款hero风格(海报backdrop+左下文字+右下主演导演+下方简介)。字幕选择功能待后续(需摸清KSPlayer/mpv字幕轨API)。"
}
