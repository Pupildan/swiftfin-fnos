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
    static let version = "v110"

    /// 本版主要变更摘要
    static let changes = "v110:续播封面完全脱离FNOSAsyncImage管线。用强引用字典[String:UIImage]直接持有图片, resumeCard用Image(uiImage:)渲染, 无async/无缓存/无spinner/无闪动可能。每次rebuildResumeEntries后下载全部封面进字典, 永不驱逐。"
}
