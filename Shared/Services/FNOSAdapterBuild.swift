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
    static let version = "v143"

    /// 本版主要变更摘要
    static let changes = "v143:1)修按下键Hero残留半屏——原生最小reveal只把首卡拉到屏幕底缘(滚约290pt),现焦点从Hero进入海报墙时显式滚到墙顶(ScrollViewReader+scrollTo,详情归还路径标记intent不触发),视觉结果=v133。2)Hero翻页/焦点全链路诊断日志(onMoveCommand投递、pageNext/pagePrevious节流与边界、焦点迁移、海报墙焦点)回传开发机,定位切换失效的真实断点。"
}
