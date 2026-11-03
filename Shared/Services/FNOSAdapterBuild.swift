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
    static let version = "v94"

    /// 本版主要变更摘要
    static let changes = "v94（服务端探测定案，测试账号授权下的原生 API 探测）：①多端同步真通道——飞牛原生 POST /play/record {media_guid,item_guid,ts}（协议取自飞牛 Web 播放器 JS，实测 200 落库、GET /play/list 可见），播放器起播/每10s/停止三段上报全部切换到原生协议，兼容层 Sessions 空壳弃用；②评分实装——play/info 的 vote_average（飞牛刮削 TMDb 分）→ 详情页星级徽章；③色彩徽章增强——play/info 的 media_stream.color_range_type 直读（剧集可用），dv_profile 探测仍最高优先。测试账号密码可在飞牛后台修改，不影响已发版功能。"
}
