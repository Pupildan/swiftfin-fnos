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
    static let version = "v60"

    /// 本版主要变更摘要
    static let changes = "无感切换：开局检测片源(杜比视界/AV1 自动用 mpv，其余仍用 KSPlayer)，元数据漏报时按解码轨实测二次切换并带进度续播；KS 控制条按钮统一为 Hero 同款胶囊外观(去掉系统白方块)；首页媒体库标题字号调小"
}
