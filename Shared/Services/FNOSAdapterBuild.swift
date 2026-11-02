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
    static let version = "v40"

    /// 本版主要变更摘要
    static let changes = "回退播放源为 GET Items/{id} 并改宽松解析(修复播放失败)；Hero 按钮改为与详情页同款视觉(独立实现)；详情页新增演员阵容(飞牛数据)；详情页背景按海报自动取色生成动态渐变"
}
