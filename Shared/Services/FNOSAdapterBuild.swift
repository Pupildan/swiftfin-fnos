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
    static let version = "v88"

    /// 本版主要变更摘要
    static let changes = "v88 修复：①详情页播放 cover 漏传 startFraction（v87 续播在详情入口完全失效的根因：按钮文字对但点击从头播、续播弹窗不出现）——补传后详情/卡片两条入口都带进度；②转盘/滑动拖进度失效——FNOSPanBridge 全局单例闭包绑死旧会话状态，第二次播放起手势写进已销毁 State；改为每次进入播放器清旧重挂（panAttached 防同会话重复），onDisappear 兜底清空。自动连播功能本身未动，之前因拖动失效无法拖到片尾测试。"
}
