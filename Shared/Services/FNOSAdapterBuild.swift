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
    static let version = "v186"

    /// 本版主要变更摘要
    static let changes = "v186:①修内嵌字幕不显示:裸KSVideoPlayer不含KSPlayer字幕UI,subtitleModel已解码但无人渲染——进度tick读subtitleModel.parts自行叠加字幕渲染层,选择轨道后即可显示。②修继续播放直进播放器选集失效:分集数据由详情页传入,直进时为空——新增自行补拉(Shows/{SeriesId}/Episodes带Overview)。③换集面板重做:每页4集大卡(缩略图+集数+标题+简介2行),玻璃底分页(上一页/下一页)。④音轨/字幕弹层改液态玻璃+标题区分(音轨切换/字幕切换)+自绘聚焦(白底黑字),字幕图标改character.textbox与弹幕区分。⑤聚焦白块已由v183 FNOSBareButtonStyle根修。"
}
