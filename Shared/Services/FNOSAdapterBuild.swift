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
    static let version = "v163"

    /// 本版主要变更摘要
    static let changes = "v163:修「媒体库按下键闪一下焦点跑回继续播放」。根因:行间移动焦点经过瞬态nil(引擎释放旧焦点→滚动曝光新行→获取新焦点),瞬态nil触发卸载分支(三行移除=闪)→新卡片聚焦又触发挂载+首卡纠正(焦点回首卡)。修复:卸载改「延迟400ms+可取消」——nil后400ms内任何卡片重新聚焦即取消卸载(行间移动),仅nil持续(真回Hero)才卸载+滚顶。"
}
