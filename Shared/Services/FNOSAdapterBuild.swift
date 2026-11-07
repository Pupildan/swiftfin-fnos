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
    static let version = "v170"

    /// 本版主要变更摘要
    static let changes = "v170:按用户指令回退+新增。①弹幕组件回退到v168实现(逐字节git checkout恢复,TimelineView每帧推导滚动正常;唯一保留改动=字号21→26)。②豆瓣评论卡:可聚焦按钮(.card),确认键打开屏幕居中弹窗完整显示全文(不再用v169行内lineLimit展开)。③弹窗背景=iOS26液态玻璃.glassEffect(.regular)+黑色压暗scrim保证可读;文字纯白、零阴影(用户明令)。弹窗含关闭按钮(确认键)+Menu(ExitCommand)均可退出。番剧侧零改动。"
}
