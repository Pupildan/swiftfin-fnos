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
    static let version = "v78"

    /// 本版主要变更摘要
    static let changes = "v78 修复：①详情页改回 fullScreenCover（cover-at-land：飞行层落地才 present 详情，系统原生处理 Menu），修复 v77 详情页按返回高概率退出到系统桌面；②实装同行推出（行副本 ±3 张 scale 3.0 锚定焦点卡，行内容 frame 捕获 1:1 对齐）；③飞行层期间按 Menu 可取消过渡。核心缩放与 v77 一致。"
}
