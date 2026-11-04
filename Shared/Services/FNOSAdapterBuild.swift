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
    static let version = "v120"

    /// 本版主要变更摘要
    static let changes = "v120:加入影视库功能上线。热门影视详情页按钮接 MoviePilot 订阅：点击即发起订阅(自动搜种/推下载/入库)，按钮三态(加入影视库/已订阅下载中/已在库中)，已在库中=飞牛库内标题探测+MP订阅态双查。设置面板新增 MoviePilot 服务地址+API 密钥。API 契约全部实测(X-API-KEY 头)。番剧入库需 ID 映射二期接入。"
}
