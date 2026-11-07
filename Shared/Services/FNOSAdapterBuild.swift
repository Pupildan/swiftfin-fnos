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
    static let version = "v175"

    /// 本版主要变更摘要
    static let changes = "v175:①修评论弹窗内容不能滚动:FNOSReviewPopupSheet内容区定高560+内容.focusable(),焦点进入滚动区up/down即可滚看全文。②弹窗外内容高斯模糊:presentationBackground改.ultraThinMaterial(磨砂模糊背后详情页)。③评论卡底增加透明度:撤glassEffect(深色页上偏深)改轻透填充white0.08(豆瓣+番剧)。④修弹幕marquee循环复位轻微停顿:estWidth改NSString+实际字体精确测宽(原1.05em/0.65em估宽误差→复位跳变),循环无缝。"
}
