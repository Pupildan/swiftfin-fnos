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
    static let version = "v173"

    /// 本版主要变更摘要
    static let changes = "v173:①豆瓣评论卡默认折叠3行、卡底改液态玻璃(与弹窗同款glassEffect),文字纯白;确认键弹窗改共享组件FNOSReviewPopupSheet(内容区maxHeight+ScrollView,修v172固定620高导致长评显示不全)。②评论功能1:1复刻到番剧详情页:评论解析升级返回作者+正文,「相关条目」栏下新增短评区(标题+总条数/可聚焦卡片/确认键弹窗),Hero弹幕复用同一批数据。③修KS/MPV播放器弹幕闪烁:FNOSDanmuView弃Canvas每帧全量重绘,改原生Text.position(每条一视图,SwiftUI只做transform合成),引擎时间轴/锚点零改动,仅换渲染层。"
}
