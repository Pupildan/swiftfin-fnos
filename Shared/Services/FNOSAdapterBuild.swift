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
    static let version = "v209"

    /// 本版主要变更摘要
    static let changes = "v209:v208 真机反馈 MPV 两修(KS 已完美不动)。①选集闪一下就没=ticker 250ms 焦点兜底的跳过条件只有四弹层不含选集条,展开后焦点移到集数卡 focus 变 nil 被兜底拽回播放键,chip 失焦触发 onChange 关条;修=兜底跳过条件加 showEpisodeStrip。②不能快速滑动进度条=滑动桥 guard 把 began 拦死(控制条隐藏时连唤出都不发生)且 ticker 自动隐藏无 scrubActive 守卫(快速大幅拖动超 5s 被中断焦点被拽走拖动结果丢失);修=滑动桥结构对齐 KS(弹层让位单独判断+began 时控制条隐藏则唤出+began/changed 刷活动时间)+自动隐藏条件加 !scrubActive。"
}
