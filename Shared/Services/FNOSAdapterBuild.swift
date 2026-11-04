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
    static let version = "v98"

    /// 本版主要变更摘要
    static let changes = "v98：TV直播/古风热歌MV 两行搁置下架（功能代码全部保留带 📴 标记，随时可启用）——实测库数据通道已通（权限头修复后 81 频道/文件条目可拉），卡在播放层：直播直链 mpv 拉流失败（疑直播源不支持 range，需抓飞牛自家播放器流协议）、MV 为多级目录树（下钻已实现，最深层文件 play/info 返回 -6 待探）。其余功能不受影响：电影/剧集续播（含弹窗/自动连播）、多端同步（原生 play/record 三段上报）、评分/色彩徽章、继续播放合并数字（诊断证实 runtime 全部正确）。"
}
