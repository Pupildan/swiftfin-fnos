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
    static let version = "v168"

    /// 本版主要变更摘要
    static let changes = "v168:修frodoGet签名缺/api/v2前缀(实测缺前缀HTTP400、带前缀200——v129起celebrities/reviews/photos三通道全部静默失效:演员头像退化文字、短评弹幕不出现、Hero横图退回竖版,一个根因三症状;MoviePilot apiv2签名用完整路径,照抄时漏了前缀)。②新增相似推荐行(frodo /recommendations 实测200,电影/剧集同款,160x240海报+标题TMDB同款,点按递归进详情)。③豆瓣弹幕预热prewarmLanes=2:打开即有弹幕在屏,杜绝首几秒空白被误判为没有弹幕;组件默认0,番剧页零改动。"
}
