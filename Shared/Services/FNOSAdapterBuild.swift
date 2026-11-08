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
    static let changes = "v189:①播放器三弹窗按用户指令重做:背景presentationBackground(.clear)不再糊视频(视频在播放必须看得见),按钮改官方tvOS26液态玻璃buttonStyle(.glass/.glassProminent),删自绘白胶囊;②内嵌字幕两修:正strokeWidth转负(CoreText正宽度=只描边=空心骨架字,转负=填充+描边同绘,恢复白字黑边本意)+sizeThatFits按文本实际高度布局(修字幕显示在屏幕正中,现贴底);③自动跳过片头片尾定论:服务端12样本skip值全null/缺失=服务端无跳过数据,客户端v184链路无bug;④诊断通道修复(v188已含:FNOSDiag并入FNOSDiagLog.send)。"
}
