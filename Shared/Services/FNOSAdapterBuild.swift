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
    static let version = "v127"

    /// 本版主要变更摘要
    static let changes = "v127:入库按钮(已在库中/加入影视库)背景改用苹果液态玻璃半透明(.glassEffect),替换原先 inLibrary 的绿底。适用于热门影视+热门番剧详情页。豆瓣热门行/其它功能未动。"
}
