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
    static let version = "v81"

    /// 本版主要变更摘要
    static let changes = "v81 修复「详情过渡动画消失」：根因锁定为 v78 起的行级 frame 捕获（LazyHStack background preference）在真机上疑似不触发，飞行上下文恒为空 → 每次点卡片都静默退化直出。现改为双层来源：卡片级 GeometryReader 实时捕获（焦点卡点按瞬间必可见，frame 最新鲜）为主，行级推算为兜底；新增屏显诊断 toast（⚠️退化直出+缺失项 / ✓起跳+frame 来源），确认根因后 v82 移除。v80 的返回焦点与行副本锚点修复保留。"
}
