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
    static let version = "v217"

    /// 本版主要变更摘要
    static let changes = "v217:三大修复。①弹幕匹配按 danmu-api 官方逻辑重写:构造标准文件名(剧名.S01E02.年份.1080p.WEB-DL.mkv)交 POST /api/v2/match 由服务端 extractTitleSeasonEpisode 解析季集,替换旧版自造候选名盲取 matches.first;新增剧名/集号一致性校验(拒绝错配),search/episodes 兜底按官方优先级(标题数字>episodeNumber字段>序号);KS/MPV 两引擎均传季号+年份。②弹幕渲染换 CATextLayer 图层引擎(本机 FNOSKit/Danmaku 移植,每帧只改 position/GPU 合成/CADisplayLink 120Hz),替掉 SwiftUI TimelineView 每帧重建视图树造成的卡顿;设置面板全部 @AppStorage 项(字号/透明度/速度/区域/垂直偏移/隐藏底部)直连引擎 API;时间源仍走 engine anchor 外推,sync 铁律一行未动。③倍速切速瞬间弹幕错位:KS/MPV/状态回调三处 setRate 改用播放器真实时间重建锚点。"
}
