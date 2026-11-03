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
    static let version = "v93"

    /// 本版主要变更摘要
    static let changes = "v93 修继续播放卡进度条/剩余时间错误：飞牛同一响应里位置与时长的 tick 单位不一致（位置≈100ns、时长≈微秒），直接做比值必错。改为位置/时长各自按宽边界归一化成秒（100ns/微秒/毫秒/秒试探）再取比值，剩余时间统一用归一化后的最优时长；本机条目的时长基准同理（条目 ticks 归一化优先，播放器实测兜底）。多端同步需飞牛原生进度端点（兼容层 Sessions 为空壳已定案），待服务端探测后接入。"
}
