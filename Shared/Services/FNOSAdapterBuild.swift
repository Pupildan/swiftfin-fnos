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
    static let version = "v41"

    /// 本版主要变更摘要
    static let changes = "修复详情页播放失败(播放器改在详情页内打开，避免 cover 竞态取消请求)；详情页背景剧照每2秒轮播；删除关于区块；演员卡片加高显示完整角色名；Hero 按钮去掉外描边"
}
