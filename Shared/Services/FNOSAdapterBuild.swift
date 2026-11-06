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
    static let version = "v159"

    /// 本版主要变更摘要
    static let changes = "v159:移除下键守卫,恢复单次下键进海报墙。依据:v140-v144(无.down处理器+无守卫)真机验证轻触不跳——守卫防的「引擎空间跳」路径基本不存在,守卫只在伤害正常下键。跳焦主路径(.down→onDownToShelf)已在v158删除。保留:v143半屏修复(进入滚墙顶)+v150回Hero滚顶+行排查器(掩码只控行显示,拉取常开)。回答用户质问:TMDB从未实锤(变量是.down处理器非任何行);双击下键是v151守卫的产物,本版移除。"
}
