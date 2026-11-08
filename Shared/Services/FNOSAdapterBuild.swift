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
    static let version = "v182"

    /// 本版主要变更摘要
    static let changes = "v182:①修聚焦白块:.plain按钮聚焦时tvOS系统自绘白色高亮块,九处内容行按钮加.focusEffectDisabled()关掉系统效果,只留自绘描边+缩放(Hero按钮同款模式)。②人物弹窗显示完整信息:豆瓣新增frodoCelebrityDetail打/celebrity/{id}取extra.info键值对(性别/出生日期/出生地/中英文名/家人/IMDb),TMDB补生日·出生地,番剧新增personSummary/characterSummary拉v0简介;信息行+简介切行逐行focusable滚动。③人物弹窗与豆瓣评论弹窗删除关闭按钮,Menu关闭(弹窗内容行可聚焦,Menu正确路由)。④确认豆瓣frodo人物端点无简介正文(extra.info即全部可得信息)。"
}
