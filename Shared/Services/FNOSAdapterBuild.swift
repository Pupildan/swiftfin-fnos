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
    static let version = "v180"

    /// 本版主要变更摘要
    static let changes = "v180:①修入库操作后/已入库内容详情页下键失效(根因:入库按钮是Hero区唯一可聚焦元素,libState!=idle时.disabled禁用→焦点释放且引擎不滚动重落点→焦点nil→下键无起点;与前两轮分区.focusable改动无关)。移除三详情页入库按钮.disabled,action已有幂等守卫不会重复订阅。②演员/角色/制作人员头像全部可点击:新增FNOSPersonPopupSheet人物弹窗(大头像+姓名+角色,TMDB附官方简介按长度切行滚动),豆瓣演员/TMDB演员/番剧角色·制作人员四处接线。③确认死代码:TMDB infoSection从未被body引用(内含重复演员行),待后续清理。"
}
