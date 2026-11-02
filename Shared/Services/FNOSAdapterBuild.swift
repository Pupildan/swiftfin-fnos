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
    static let version = "v33"

    /// 本版主要变更摘要
    static let changes = "修复Hero图文错位(文案随翻页动画同步/图片复用清空/刷新清旧数据)；修复焦点离开Hero后预告仍在播放；修复媒体库返回Hero闪退(每次预告用全新Coordinator)；设置新增Hero图源切换(横图/竖版海报)"
}
