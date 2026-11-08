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
    static let version = "v189"

    /// 本版主要变更摘要
    static let changes = "v189:①播放器三弹窗(弹幕设置/音轨/字幕)承载方式从.sheet改为播放器内overlay——.sheet在tvOS系统自带压暗且玻璃只能对暗背景折射=死灰板无玻璃感(用户实测实锤),overlay与视频同层级glassEffect直接对播放画面折射=真液态玻璃,无压暗不糊视频;按钮全用官方tvOS26液态玻璃.buttonStyle(.glass/.glassProminent);②弹窗焦点:appear后200ms程序化落首行(overlay不保证焦点自动移入,v173教训),Menu键onExitCommand关闭,关闭回控制条播放键;③内嵌字幕两修:正strokeWidth转负(CoreText正宽度=只描边=空心骨架字,转负=填充+描边同绘恢复白字黑边)+sizeThatFits按文本实际高度布局(修字幕居中,现贴底);④自动跳过片头片尾定论:服务端12样本skip值全null/缺失=服务端无跳过数据,客户端v184链路无bug。"
}
