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
    static let version = "v109"

    /// 本版主要变更摘要
    static let changes = "v109:FNOSAsyncImage实现Equatable,SwiftUI父视图重算时比较新旧结构体,相等则跳过body重算。切断焦点移动→父视图重算→续播封面被无谓重评估→闪动的链路。仅比url/usePosterCache/hardPin,忽略headers字典。"
}
