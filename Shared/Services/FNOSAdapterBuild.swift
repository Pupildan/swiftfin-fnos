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
    static let version = "v79"

    /// 本版主要变更摘要
    static let changes = "v79 修复：起跳卡隐藏/去 matched 的判断由只看 detailItem 改为同时看 flight 与 detailItem。v78 改 cover-at-land 后 detailItem 延迟到 0.46s 才设置，导致 0~0.46s 飞行期间起跳卡保留 matchedGeometryEffect，与飞行层 B 端横图形成同一 id 双 source（未定义行为，起跳可能失败/闪烁）。现飞行起跳瞬间（flight 设置时）起跳卡即隐藏去 matched，恢复 v77 已验证的 B 端从最后 frame 起跳配置。"
}
