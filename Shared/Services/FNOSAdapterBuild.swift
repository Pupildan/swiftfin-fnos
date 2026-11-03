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
    static let version = "v69"

    /// 本版主要变更摘要
    static let changes = "修复详情页过渡动画丢失：改用 NavigationStack(path:)+NavigationLink(value:)+navigationDestination(for:) 标准 push 语义触发系统 zoom（此前 Button+isPresented 布尔翻转导致 zoom 源无法被捕获，过渡退化成无动画），并移除 push 瞬间禁用主页的 .disabled 修饰符"
}
