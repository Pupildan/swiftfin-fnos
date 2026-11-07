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
    static let version = "v176"

    /// 本版主要变更摘要
    static let changes = "v176:①修评论弹窗内容不能滚动:ScrollView自身.focusable()(tvOS聚焦ScrollView即整屏滚动,原逐Text.focusable未把滚动视口变焦点目标)。②豆瓣相似推荐行/番剧相关条目行撤外层.focusable(同v172评论根因:整段成一个焦点目标→下键跳过卡片/确认无反应),保留.focusSection,卡片原生可聚焦。③豆瓣影评弹窗全文按影评id缓存,重开即时显示(原首次只出摘要需返回再进)。④弹幕marquee改NSString+实际字体精确测宽,循环复位无缝消停顿。"
}
