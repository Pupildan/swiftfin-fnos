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
    static let version = "v76"

    /// 本版主要变更摘要
    static let changes = "修复实装版与 Demo 效果不一致：①详情改覆盖层架构（与 Demo 一致），放大到位后原地呈现、无 fullScreenCover 硬切闪烁；②放大终点改为全屏（与详情 hero 完全同位，零跳变）；③行放大修复为与起跳同一动画事务（此前瞬间跳变）；④点卡后原卡片隐藏（焦点玻璃不再残留）；⑤详情打开时禁用底层全部焦点（Menu 可靠关闭）；返回反向缩回与 Demo 对称"
}
