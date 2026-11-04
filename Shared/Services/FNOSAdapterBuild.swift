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
    static let version = "v112"

    /// 本版主要变更摘要
    static let changes = "v112:三修。1)TMDB API Key改SecureField密文显示+清晰可编辑样式+已填写确认。2)热门推荐海报文字移出Button不抢焦点。3)FNOSPosterTile加Equatable(比item.Id+width),焦点移动时媒体库海报瓦片不再被无谓重渲染闪动。"
}
