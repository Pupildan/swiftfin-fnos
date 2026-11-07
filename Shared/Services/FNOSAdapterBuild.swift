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
    static let version = "v167"

    /// 本版主要变更摘要
    static let changes = "v167:①豆瓣详情页Hero换横屏高清剧照(frodo /photos kind=s 两页窗口,横屏优先按分辨率降序,规范化imgN doubanio /l/ 高清直链;竖版海报aspectFill垫底兜底,不再拉伸放大糊画)。②豆瓣内容区严格对齐TMDB版式:主要演员(80pt头像行)/评论/制作信息卡(label100+value18同款)三段独立focusable。③豆瓣+番剧详情页Hero短评弹幕:顶部带匀速右→左推移,TimelineView帧推导无状态机;豆瓣取frodo短评,番剧解析bangumi.tv评论页HTML;allowsHitTesting(false)无focusable,不碰焦点引擎。"
}
