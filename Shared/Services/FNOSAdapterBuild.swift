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
    static let version = "v123"

    /// 本版主要变更摘要
    static let changes = "v123:1)海报标题自动换行不超海报宽度。2)TMDB/番剧详情页数据补全(标语/片长/评分人数/制作信息/预告/相关推荐,番剧修评分+infobox+制作人员+相关条目)。3)Hero背景海报取色高斯模糊+左下文案重排+右下主演导演。4)下键内容区新增logo+主演行+预告花絮行(Piped拉流播放)+相关内容行,TMDB智能匹配,番剧走Bangumi数据。"
}
