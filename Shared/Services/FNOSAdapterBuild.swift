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
    static let version = "v183"

    /// 本版主要变更摘要
    static let changes = "v183:修聚焦白色色块(.focusEffectDisabled压不住):FNOSMainView内FNOSBareButtonStyle注释早在v76时代就记录了根因——.plain/.borderless在ScrollView内仍会画系统焦点板(白圆角框),正解=空ButtonStyle让系统无可绘制外观。九处内容行按钮.buttonStyle(.plain)全部换FNOSBareButtonStyle(Hero按钮同款),保留.focusEffectDisabled()+自绘液态玻璃描边+轻微放大(用户指定效果)。聚焦时:头像/海报白描边+1.05-1.08放大,无任何系统底板。"
}
