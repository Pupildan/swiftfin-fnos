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
    static let version = "v92"

    /// 本版主要变更摘要
    static let changes = "v92（全屏诊断首图定案）：①本机播放记录上首页——本地进度改存完整条目 JSON（单集自带海报/集号/时长），继续播放=本机记录优先+服务端多端记录补位合并；v91 的海报墙反查会漏掉所有剧集记录（单集不在条目池）已废弃；②mpv 引擎进度回调带总时长，两引擎本地记录统一；③评分数据接线第一步：play/info 的 item 字段表全量 dump 进全屏诊断（飞牛确有评分数据，真实字段名待截图确认后按名接线）。"
}
