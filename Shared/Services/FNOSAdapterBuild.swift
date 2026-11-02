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
    static let version = "v38"

    /// 本版主要变更摘要
    static let changes = "新增影视详情页(1:1 复刻 Apple TV+)；修复 Hero 一直拿不到横版大图的 bug(Backdrop tag 在 BackdropImageTags 数组)；海报改后台解码消除切换卡顿；去掉无效的液态玻璃高光"
}
