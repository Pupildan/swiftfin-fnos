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
    static let version = "v156"

    /// 本版主要变更摘要
    static let changes = "v156:逐行排查开关。经典模式实验证实跳焦源=三行内容/其运行时面。设置里「内容行排查」循环切换器:全部显示→隐藏番剧→隐藏TMDB→隐藏豆瓣→仅海报墙,每按一次换档即时生效。真机逐档轻触测试,定位到具体行后精准修。基于rowMask位掩码(1=豆瓣,2=TMDB,4=番剧),隐藏行同时跳过其拉取。"
}
