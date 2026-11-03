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
    static let version = "v95"

    /// 本版主要变更摘要
    static let changes = "v95：①TV直播 / 古风热歌MV 数据行实装——服务端探测证实兼容层 /Items 对这两类库返回真空（/LiveTv 路由不存在），改走原生 item/list + ancestor_guid 过滤（实测 TV直播 81 频道 / 古风MV 文件条目），海报经原生 sys/img 鉴权直通；点击播放需原生直播流/文件直链协议，本版先出列表（点击给提示），播放接入下一版；②继续播放诊断加强：每条记录的秒数/比例/时长基准进全屏诊断。多端同步（原生 play/record 三段上报）与评分（vote_average 星级）v94 已实装。"
}
