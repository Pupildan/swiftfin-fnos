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
    static let version = "v213"

    /// 本版主要变更摘要
    static let changes = "v213:继续播放入口选集失效第二根因修复(v212 未命中)。v212 修的是容器 compat/KS 侧,但继续播放条目带 nativePosterURL→nativeItemGUID 直通→走 mediaRange(itemGUID:) 原生链路,该方法 episodes 恒空(换直链专用),MPV 选集条被 guard !episodes.isEmpty 拦死展不开——这才是用户看到的现象(继续播放入口几乎全走这条 mpv 直链)。修=mediaRange(itemGUID:) 用 play/info 的 parent_guid(剧集/季级)补拉同剧分集:先 season/list 拿第一季 guid,失败把 parent_guid 直接当季 guid(episode/list 对非季 guid 返回空=无害);episodeNumber 从分集列表按 guid 反推(选集条当前集高亮);电影/直播 parent_guid 无季列表=分集空,行为与旧版一致。"
}
