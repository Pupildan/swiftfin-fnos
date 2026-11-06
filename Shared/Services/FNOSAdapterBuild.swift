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
    static let version = "v150"

    /// 本版主要变更摘要
    static let changes = "v150:轻触跳焦新假设——跳焦与滚动位置相关。证据链:轻触被分类为.down→走v98接线的onDownToShelf落到继续播放(v140-v144无.down分支故不跳);v100不跳的解释=测试时页面停在顶部(引擎下方无屏内目标,模糊向量被忽略),而v148/v149测试前做过下键导航,页面停在半滚动状态(引擎最小reveal只拉到视口底缘),继续播放卡在屏内一点即中。本版:焦点回到Hero时整页滚回顶部(恢复v100静止条件,也是ATV+正确视觉);onDownToShelf加诊断日志区分handler路径vs引擎路径。Hero文件不动。"
}
