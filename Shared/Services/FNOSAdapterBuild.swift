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
    static let version = "v207"

    /// 本版主要变更摘要
    static let changes = "v207:片头片尾面板重做(用户规格)——面板实时显示当前播放位置;聚焦行按确认键=取当前位置做片头结束点/片尾开始点;左右键或触摸板滑动=±1秒微调(连按加速),直接改值立即生效;捕捉=标记此处(本次播放不再自动跳,下次播放起效);0=关闭。服务端实测:剧集配置写 parent_guid 后 play/info 同集与同剧另一集均回读成功(多端同步可用);电影服务端不回读 play_config,面板会提示仅本次播放生效。面板打开/捕捉/推送全链路诊断落 9999 日志。"
}
