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
    static let version = "v215"

    /// 本版主要变更摘要
    static let changes = "v215:继续播放选集第四根因(9999 日志实锤+服务端直探验证)。v214 日志显示分集自拉(Shows/Episodes)失败「未能读取数据,因为数据缺失」——兼容层 Shows/{sid}/Episodes 不带 SeasonId 时 HTTP 200 但 body=null(len=4),JSONDecoder 对 null 报此错;test 账号直探验证:带 SeasonId 则返回完整分集(12 集)。修=对齐详情页 loadEpisodes:先 Shows/{sid}/Seasons 拿季列表,再逐季带 SeasonId 拉 Episodes 拼接(多季剧全覆盖),Items 兜底保留(实测 0 集无害)。附:兼容层 Episode 的 SeriesId 需 Fields 显式请求(v214 已修);parent_guid 实测为季级 guid(单季剧=剧级效果)。"
}
