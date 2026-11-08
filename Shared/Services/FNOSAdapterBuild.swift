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
    static let version = "v187"

    /// 本版主要变更摘要
    static let changes = "v187:按用户指令回滚v186——仅保留:①内嵌字幕显示修复(裸播放视图渲染subtitleModel)②字幕切换按钮图标(character.textbox)③弹层标题区分(音轨切换/字幕切换)。回滚:换集面板网格重做、继续播放补拉分集、音轨/字幕弹层玻璃化(全部还原为v185状态)。自动跳过片头片尾诊断保留(play_config原始内容上报)——等待真机播放凡人修仙传抓取数据定位真因。"
}
