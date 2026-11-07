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
    static let version = "v171"

    /// 本版主要变更摘要
    static let changes = "v171:①修弹幕闪烁(豆瓣+番剧共用组件):删TimelineView每帧重建(20fps步进=闪烁根因),改文本链双拷贝+repeatForever纯线性offset(GPU transform,60fps平滑零重绘);不用preference测宽/不用drawingGroup(v169死因),链宽确定性估宽直算保证滚动;字号26。②豆瓣评论头显示总条数(frodo comment_count,如「评论 258 条」)。③评论弹窗背景严格透明液态玻璃:撤0.85黑scrim(用户看到的灰底),加presentationBackground(.clear)让详情页透在玻璃后,纯白文字零阴影。"
}
