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
    static let version = "v86"

    /// 本版主要变更摘要
    static let changes = "v86 反馈修复：①继续播放卡对齐 ATV+ 版式——名称与信息行直接叠图（底部渐变），进度条改 74pt 短条，信息行=剧集「第N集 · 剩X分」/电影「剩 X小时Y分钟」，只展示最近 6 条；②空媒体库行隐藏（tv直播/古风热歌mv 返回 0 条时不再显示空行，日志加诊断提示——LiveTV 类库需专用端点，后续版本接）；③本机播放记录同步到服务端——起播/每10s/停止三段上报（Jellyfin 标准 /Sessions/Playing*，KS 与 mpv 双引擎都接，兼容层未实现则静默失败不影响播放；tick 按微秒上报与 RunTimeTicks 实测一致）。"
}
