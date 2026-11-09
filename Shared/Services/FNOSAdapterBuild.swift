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
    static let version = "v203"

    /// 本版主要变更摘要
    static let changes = "v203:MPV 弹幕白变灰诊断版(用户实测 v202 hdrPolicy .disabled 仍不白,静态分析到极限)——新增两路诊断日志落 9999:①弹幕数据层=加载时上报总条数/白色条数/前5个颜色原始值/用户不透明度设置(验证数据层是否纯白)②MPV渲染管线=起播3秒后上报 renderColorStatus/hdr 元数据/DV 状态(验证 EDR 是否真被 .disabled 关掉);日志在 output/tvos-client.log,实锤后精准修。"
}
