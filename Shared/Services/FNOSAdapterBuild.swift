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
    static let version = "v147"

    /// 本版主要变更摘要
    static let changes = "v147:UIPanGestureRecognizer水平滑动翻页(tvOS可用,替代tvOS不可用的DragGesture)。Hero区域覆盖透明UIView+UIPanGestureRecognizer,水平分量占优时翻页(左滑=下一页,右滑=上一页),垂直分量占优时交给ScrollView滚动。cancelsTouchesInView=false+shouldRecognizeSimultaneouslyWith=true与ScrollView共存。焦点路由零改动。"
}
