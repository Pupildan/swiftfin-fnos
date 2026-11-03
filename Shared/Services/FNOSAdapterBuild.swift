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
    static let version = "v70"

    /// 本版主要变更摘要
    static let changes = "修复详情页过渡动画丢失的真正根因：navigationDestination(for:) 误挂在 NavigationStack 外层（兄弟位置）会被 SwiftUI 静默忽略，导致 zoom 的 matchedTransition 上下文断裂、过渡退化无动画；已将其移入 NavigationStack 内部（根视图上）"
}
