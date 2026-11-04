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
    static let version = "v108"

    /// 本版主要变更摘要
    static let changes = "v108:v98基线+古风MV过滤+续播封面硬常驻(hardPin,12张独立字典不被任何驱逐)+详情关闭不再重建续播行(避免动画期间不必要的焦点重注册)。不含磁盘缓存/pinned LRU/warm-up/日志采集器等高风险改动。"
}
