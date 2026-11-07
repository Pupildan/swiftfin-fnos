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
    static let version = "v174"

    /// 本版主要变更摘要
    static let changes = "v174:①豆瓣评论弹窗拉全文:列表abstract是摘要截断,新增frodoReviewContent打/review/{rid}详情端点取全文(实测2284字符含HTML),剥标签解实体保留段落;弹窗先显摘要后台拉全文替换。②播放器弹幕抖动:FNOSDanmuView从.position(布局属性,每帧改触发宿主重布局→叠视频层=抖动)改.offset(纯transform,GPU合成不重布局),并去掉左右出画guard(估宽≠实宽在屏边突现/消失=跳变),出画由30s驱逐兜底。引擎锚点/轨道零改动。"
}
