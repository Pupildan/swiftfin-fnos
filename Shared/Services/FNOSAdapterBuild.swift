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
    static let version = "v172"

    /// 本版主要变更摘要
    static let changes = "v172:修豆瓣评论区焦点进不去(用户真机:焦点无法在每条评论间切换/确认无弹窗)。根因=评论区外层.focusable()把整段当成一个焦点目标,焦点跳过所有评论卡直达下一节。撤掉该.focusable(),保留.focusSection()引导引擎进入本节,评论卡自身Button(.card)原生可聚焦→可逐条下移→确认开弹窗(海报墙同款模式)。弹幕/弹窗/评论计数均未动。"
}
