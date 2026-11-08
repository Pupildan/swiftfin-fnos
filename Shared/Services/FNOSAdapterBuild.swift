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
    static let version = "v181"

    /// 本版主要变更摘要
    static let changes = "v181:①修内容区各分区无法点击:分区外层.focusable()把整段变成单一焦点目标,焦点落在分区上进不了内部按钮→确认无反应(v178恢复它们是因为当时误判已入库下键失效的根因,v180实锤真因=入库按钮.disabled后,这些包裹已无必要)。摘除豆瓣演员·相似推荐/TMDB演员·预告·花絮·相关内容/番剧角色·制作人员·相关条目共8处外层.focusable(保留.focusSection),与豆瓣评论(无包裹可正常点击)同构。②撤内容区按钮.card灰底(tvOS26 .card常驻渲染玻璃底,头像/海报不铺满即露出):改.buttonStyle(.plain)+逐项.focused聚焦定位+自绘聚焦描边/缩放,未聚焦时与历史外观一致零灰底。评论卡与入库按钮样式不动。"
}
