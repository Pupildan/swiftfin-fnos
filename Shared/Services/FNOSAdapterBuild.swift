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
    static let version = "v200"

    /// 本版主要变更摘要
    static let changes = "v199:搜索框改用官方 searchable 系统搜索框(用户指令:放弃自绘,用官方试试)——输入框/键盘/聚焦外观全部由系统绘制,App 不再画任何背景(自绘胶囊填充+系统聚焦效果叠加=灰块,自绘方案已彻底移除);实时防抖搜索(450ms 停止输入自动触发,取消上次未完成);焦点自动落在系统搜索框(onAppear searchFocused),结果区布局不变(媒体库优先→TMDB兜底→详情页/入库);注意:系统搜索框外观为 tvOS 官方样式,若键盘面板底色仍不满意属系统绘制范围。"
}
