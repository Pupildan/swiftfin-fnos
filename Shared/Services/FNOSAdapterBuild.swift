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
    static let version = "v48"

    /// 本版主要变更摘要
    static let changes = "播放页进度条下方新增换集条(缩略图横排+当前集描边)；时长按内容类型判定单位(剧集4.2e9→70分钟)；演员加 Items/{id} 备用端点+原始值诊断"
}
