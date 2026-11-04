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
    static let version = "v118"

    /// 本版主要变更摘要
    static let changes = "v118:三修。1)海报文字间距16→24(焦点放大动画不再压字)。2)热门影视行删除年份显示。3)两个详情页强解包URL(string:)!全改flatMap空字符串返回nil,修复有概率闪退。"
}
