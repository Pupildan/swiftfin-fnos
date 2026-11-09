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
    static let version = "v204"

    /// 本版主要变更摘要
    static let changes = "v204:MPV 弹幕白变灰根因闭环(诊断日志实锤)——日志证实:弹幕数据纯白(77119条中98%白色/样本ffffff/不透明度100%)+渲染层已是 SDR(configuredDynamicRange:.sdr)+颜色解析正确,灰只能来自显示模式;漏网之鱼=displayMatching .automatic 仍按杜比视界片源把电视切进 HDR 显示模式,HDR 模式下系统把 SDR 浮层压暗到 203 尼特参考白;修复=displayMatching:.disabled(官方现成档位,detach 显示匹配协调器,电视留在 SDR 模式)+保留 hdrPolicy:.disabled(渲染层 SDR)。两者皆关后 mpv 全链路 SDR,弹幕/字幕/控制条恢复真实白色。"
}
