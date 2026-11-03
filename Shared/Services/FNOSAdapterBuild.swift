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
    static let version = "v89"

    /// 本版主要变更摘要
    static let changes = "v89（依据诊断面板首张截图定位）：①进度上报单位修正——按标准 Jellyfin 100ns（1e7/秒）上报；v86 按微秒发、服务端照单全收但进度存成 1/10，低于续播阈值永不进 Resume（诊断证实 Resume 端点通、上报无失败日志）；②首页「继续播放」在播放器/详情关闭时静默刷新，本机播完立刻上榜；③详情页关闭播放器立刻重读本地进度，按钮状态即时刷新；④诊断补全——HTTP 级加载失败（古风mv 无痕消失的漏埋点）、上报成功留痕、续播链路（记录秒数/弹窗/静默/断链）每次播放留一行。TV直播确认为兼容层无条目的独立功能（服务端返回真空列表），需 fnOS 原生 IPTV 端点另立项。"
}
