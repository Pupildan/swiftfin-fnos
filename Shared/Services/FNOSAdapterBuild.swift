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
    static let version = "v169"

    /// 本版主要变更摘要
    static let changes = "v169:弹幕体验重写(豆瓣+番剧hero共用组件):①字号21→26加大。②弃全部时间判定(删TimelineView/Date逐帧推导,20fps步进=闪烁根因)——每泳道=文本链双拷贝+repeatForever纯线性offset,CoreAnimation只对光栅化整链做transform(60fps零重排);链身.drawingGroup()强制GPU离屏渲染,滚动期文本零重绘;每Text.fixedSize()锁行宽防长短突变;无缝循环=单份链估宽≥屏宽150+行程链宽间距。③豆瓣评论卡折叠:默认4行,lineLimit按需展开,点按卡片切换收起(长评>80字右上角提示),评论区补focusSection。番剧调用点零改动(共享组件字号/闪烁修复自动生效)。"
}
