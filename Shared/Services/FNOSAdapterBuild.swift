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
    static let version = "v82"

    /// 本版主要变更摘要
    static let changes = "v82 新增返回反向缩回动画 + 修同行推出不可见：①详情页 Menu 改由 cover 内容内 onExitCommand 拦截（可靠，Demo 同款），有卡片来源时走反向飞行——横图全屏单段弹簧缩回卡片 + 行副本 3→1 + 压暗淡出，与 Demo 反向缩回一致；Hero 来源走系统默认收场。②正向行副本 1→3 起跳由 async(0) 改 asyncAfter(0.05)——真机上 async(0) 仍可能与插入事务合并致首帧即 3 倍（推出效果不可见）。③反向不用 matched（cover 与主树不共享命名空间），用显式 frame/position/圆角插值。"
}
