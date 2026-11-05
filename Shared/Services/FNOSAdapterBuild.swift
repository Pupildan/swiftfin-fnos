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
    static let version = "v129"

    /// 本版主要变更摘要
    static let changes = "v129:1)修首页Hero焦点跳页回归(v123引入的右下主演导演覆盖层+徽章+时长破坏焦点逻辑,往右滑/按右键焦点窜到继续播放)——首页Hero彻底回滚v122,Hero增强全部移到详情页。2)豆瓣详情页用MoviePilot同款frodo私有API(HMAC-SHA1签名,_api_key=0dad551...,端点/movie/{id} id在路径)拿完整数据:简介intro/类型/主演/导演。"
}
