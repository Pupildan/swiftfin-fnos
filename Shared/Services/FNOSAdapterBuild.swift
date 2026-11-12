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
    static let version = "v214"

    /// 本版主要变更摘要
    static let changes = "v214:继续播放选集第三根因修复(用户补充:MPV 能展开但无信息,KS 展不开)。两根因:①fetchResumeItems 的 Fields 缺 SeriesId→服务端继续播放条目 SeriesId=nil→分集自拉用单集 Id 查 Shows/Episodes 必失败(KS 展不开+MPV 无信息);修=Fields 加 SeriesId+自拉时 SeriesId 缺失先补查单集元数据;②MPV 视图 compatEpisodes 是 @State(initialValue:) 首建锁死,容器后拉到的分集永远传不进(继续播放入口 MPV 先建/compat 空/拉取完成后无法更新);修=改 let 每次容器重算实时传入。另:继续播放选集链路全景诊断日志(容器引擎快照/分集自拉每步/MPV init 数据源/KS+MPV 展开动作/换集请求)落 9999。"
}
