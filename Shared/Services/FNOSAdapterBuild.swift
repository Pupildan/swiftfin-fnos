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
    static let version = "v178"

    /// 本版主要变更摘要
    static let changes = "v178:①修评论弹窗长文不能滚动:弹窗内容按长度切行、每行.focusable()(单个大Text非焦点目标,tvOS焦点引擎在ScrollView内无落点→滚不动),焦点逐行下移驱动ScrollView滚动看全文。②回滚v176:豆瓣相似推荐/番剧相关条目恢复外层.focusable()(v176撤掉后已入库内容下键进不去内容区——内部按钮非原生可聚焦)。"
}
