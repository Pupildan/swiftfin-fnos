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
    static let version = "v201"

    /// 本版主要变更摘要
    static let changes = "v201:MPV 播放中进系统屏保真根因修复(用户实测 v197 容器方案仍无效)——根因=SwiftUI Group 会把修饰符分发给每个子视图,容器上的 onAppear(true)/onDisappear(false) 在内核自动切换(KS→MPV)时各自触发且 KS 的 onDisappear(false) 后触发,最终 false → MPV 播放中进屏保;修复=①容器 Group 改 ZStack(修饰符归属容器本身,只在播放器开/关各触发一次)②MPV ticker 每 250ms 重申 isIdleTimerDisabled=true(双保险,任何路径重置都会被即刻恢复)。同含 v195-v200 全部内容(官方 searchable 搜索/滑块手感/屏保容器所有权/搜索灰块根除)。"
}
