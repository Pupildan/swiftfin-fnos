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
    static let version = "v164"

    /// 本版主要变更摘要
    static let changes = "v164:修「焦点到豆瓣行被拉回继续播放」——跨行焦点移动需要滚动曝光(引擎释放焦点→滚动→获取),曝光时长超400ms,卸载窗口太短会在曝光中途拆行→引擎目标消失→重定向回首卡。修复:卸载延迟400ms→1500ms(真回Hero时晚1.5s卸载,都在视口外无感)。"
}
