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
    static let version = "v160"

    /// 本版主要变更摘要
    static let changes = "v160:回到v157+修循环点击bug(用户指令:先完成逐行排查,结论出来再定修改方向)。1)还原v158/v159的全部改动(.down→onDownToShelf与onDownToShelf回调回归,单次下键进海报墙;守卫/滚顶移除回归v157)。2)修排查器:拉取常开不再受掩码门控(v157 bug——停在隐藏档重启后数据为空,行永远显示不回来),掩码只控行显示。待用户逐档轻触完成排查(重点:隐藏TMDB档)后再定修复方向。"
}
