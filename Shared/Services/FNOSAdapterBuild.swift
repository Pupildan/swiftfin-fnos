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
    static let version = "v91"

    /// 本版主要变更摘要
    static let changes = "v91（诊断面板第二张截图定案）：①续播改秒数直通——诊断证实剧集条目 RunTimeTicks 缺失导致比例换算失败（217s 判「从头」），本地/剧级记录的秒数直接传进播放器，比例路径仅在服务端卡片使用并加 100ns 兜底换算；②首页「继续播放」= 服务端记录 + 本机记录合并（服务端 /Sessions 上报为空壳 204 接受不入库，本机播的走 UserDefaults 索引兜底上榜），关播放器/详情即刷新；③设置页诊断改「全屏诊断」按钮——整屏一次截全，最新置顶实时刷新。TV直播维持隐藏（服务端该库确认为真空，需原生 IPTV 端点另立项）。"
}
