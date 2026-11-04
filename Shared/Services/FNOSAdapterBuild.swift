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
    static let version = "v113"

    /// 本版主要变更摘要
    static let changes = "v113:新增TMDB详情页。点击热门推荐卡片打开全屏详情页,数据全从TMDB抓取(简介/演员/类型/评分/背景图)。页面风格与媒体库详情页一致。Hero按钮为加入影视库(Phase 3 PT+QBT后续接入)。"
}
