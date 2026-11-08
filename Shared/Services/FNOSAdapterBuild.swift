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
    static let version = "v191"

    /// 本版主要变更摘要
    static let changes = "v191:①弹幕设置滑块支持触摸板/转盘滑动连续调节(面板背景挂UIKit滑动手势爬根挂载,仅弹窗开启且聚焦滑块时消费水平滑动,垂直滑动留给焦点引擎;灵敏度分项调校,直接写UserDefaults即时生效);②删除完成按钮(调节本就即时生效,Menu键关闭);③新增隐藏底部弹幕开关(玻璃行+勾选,控制引擎丢弃mode4底部固定弹幕);④字幕保护区死规则:滚动泳道下限封顶屏高-260,底部固定弹幕上移到保护区之上(height-290),弹幕永不压字幕;⑤显示区域滑块上限改为75%(保护区之上的有效范围)。"
}
