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
    static let version = "v185"

    /// 本版主要变更摘要
    static let changes = "v185:①播放器控制条新增内嵌字幕轨切换(KS):tracks(mediaType:.subtitle)列出MKV内封字幕,复用音轨同款选择弹层,captions.bubble按钮(有内嵌字幕轨才显示)。②自动跳过片头片尾诊断增强:playInfo打印play_config原始内容(有无/形状),resolveReporter打印解析结果——配合诊断日志监听器定位不生效真因。③同轮保留v184全部机制。"
}
