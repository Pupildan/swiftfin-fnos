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
    static let version = "v165"

    /// 本版主要变更摘要
    static let changes = "v165:诊断日志版(行为零改动)——onChange进入/nil迁移/挂载纠正/卸载任务执行全链路日志回传开发机,定位「焦点到推荐行瞬间拉回继续播放」的精确事件序列。1500ms卸载窗口保留。"
}
