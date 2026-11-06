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
    static let version = "v146"

    /// 本版主要变更摘要
    static let changes = "v146:DragGesture翻页(不依赖onMoveCommand/焦点引擎)。Hero容器挂.simultaneousGesture(DragGesture)——水平分量占优时翻页(w<0=上一页,w>0=下一页),垂直分量占优时交给ScrollView滚动。完全绕开onMoveCommand/焦点引擎分类问题。日志保留(hero drag w= h= btn=)。焦点路由零改动。"
}
