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
    static let version = "v90"

    /// 本版主要变更摘要
    static let changes = "v90 剧集续播修复（电影功能已全通，诊断面板证实上报 204/弹窗/记录均正常）：①剧级观看位置升级为「集号+秒数」一起存——单集条目记录缺失时用剧级秒数续播，不再回退第 1 集从头播；②mpv 引擎补齐本地进度与剧级位置记录（此前只有 KS）；③剧集续播与 mpv 路径补诊断（记录秒数/回退/从头），下一张截图可精确定位。服务端同步待 100ns 单位修正后重测（v89 已改，诊断面板有「上报成功」留痕）。"
}
