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
    static let version = "v188"

    /// 本版主要变更摘要
    static let changes = "v188:①选集面板改版(用户指令):4张大卡同屏(424宽大缩略图+集数+标题+两行简介),展开/收起/方向键/点选操作逻辑零改动;②内嵌字幕按原始信息渲染:弃固定24pt字符串,UILabel直出NSAttributedString原文(原始字号/颜色/特效不动,禁阴影;原文无字号时才补38pt基准避免过小);③播放器三弹窗(弹幕设置/音轨切换/字幕切换)液态玻璃重构,参照评论弹窗FNOSReviewPopupSheet(glassEffect+presentationBackground+自绘聚焦白底黑字);④自动跳过片头片尾诊断埋点保留(play_config上报),等待真机播放抓取。"
}
