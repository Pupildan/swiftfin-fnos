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
    static let version = "v97"

    /// 本版主要变更摘要
    static let changes = "v97：①TV直播 0 条修复——诊断证实 App 原生请求缺 X-Trim-Client 头（飞牛服务端按此识别调用方，缺失时直播库返回 Permission Error），原生 client 全量补上 web/631 头；②MV 播放实装——目录树递归下钻（play/info 探测可播 + parent_guid 逐层深入，深度 5），找到可播文件后走原生直链 mpv；③直播频道播放保持（v96 协议）。此前已实装：电影/剧集续播、自动连播、多端同步（原生 play/record）、评分/色彩徽章、继续播放合并（本机优先）。"
}
