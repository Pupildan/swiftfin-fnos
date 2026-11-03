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
    static let version = "v65"

    /// 本版主要变更摘要
    static let changes = "详情页过渡按参考重做：按下即起跳，飞行窗口用该条目主图的高清版（1920，与卡片同构图，放大不糊不滑动）；只把被点的那一行推近淡出（同行其他卡被挤出屏幕，上下行不动）；全屏后与详情页剧照交叉溶解；返回时整行一起缩回原位（同行海报有归位动画）"
}
