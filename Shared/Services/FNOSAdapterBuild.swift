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
    static let version = "v125"

    /// 本版主要变更摘要
    static let changes = "v125:1)首页Hero滑动防抖(0.45s节流,轻滑只翻一页不窜页)。2)取色高斯模糊背景从首页撤除(恢复黑底),改用到热门影视+热门番剧详情页(背景从Hero海报取色模糊)。3)热门番剧详情页套同款排版(之前漏了)。4)两个详情页Hero严格按参考图排版:左下徽章→标题/logo→类型·分级→简介→年份·时长→按钮,右下主演(角色)/导演。"
}
