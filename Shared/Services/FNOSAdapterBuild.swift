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
    static let version = "v96"

    /// 本版主要变更摘要
    static let changes = "v96：①修复 v95 引入的媒体库海报丢失——瓦片请求头跟 URL 走（compat 条目误用原生 Authx 头导致整面 401）；②直播频道播放实装——原生 play/info(频道guid) → media_guid → media/range 直链走 mpv（协议实测），点击频道直接看；③继续播放时长基准修正——本机记录以播放器实测时长优先（兼容层时长 ticks 证实为垃圾值），服务端记录以原生 /play/list duration（秒）按标题匹配优先；④MV 目录层级播放待下版（库→目录→文件多级结构需递归解析）；⑤直播频道不写续播记录。"
}
