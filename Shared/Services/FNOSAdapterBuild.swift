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
    static let version = "v212"

    /// 本版主要变更摘要
    static let changes = "v212:继续播放入口剧集选集失效修复(用户真机反馈)。根因=首页继续播放入口构造播放容器时未传 episodes 和 onSelectEpisode(详情页入口有传):KS 选集条被 guard !episodes.isEmpty 直接拦死展不开,MPV 虽能展开(原生分集)但无封面信息且 KS 换集回调为 nil 点了没反应。修=①容器自拉分集兜底:episodes 为空且是剧集时按详情页同款端点(Shows/{seriesId}/Episodes → Users/{uid}/Items?ParentId 兜底)自拉,allEpisodes 计算属性外部传入优先,所有入口自动生效,失败静默不影响播放;②首页继续播放入口补 onSelectEpisode 回调(pendingPlaybackTarget 关播重开,详情页 pendingEpisode 同款机制),换集后从头播放新集。"
}
