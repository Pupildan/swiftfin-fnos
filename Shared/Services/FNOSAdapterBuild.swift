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
    static let version = "v184"

    /// 本版主要变更摘要
    static let changes = "v184:①评论弹窗改按自然段落分行(每段一个focusable行,段内自然换行,不再110字句中硬切)。②删飞牛媒体库详情页底部临时诊断区(debugSection+body引用;debugLines管道保留为不可见缓冲)。③播放器自动跳过片头/片尾,数据与服务器同步:fnOS play/info响应原生携带play_config.skip_opening(片头结束秒)/skip_ending(片尾开始秒)(端点形状实测于参考项目fntv-electron types.ts),NativeClient.playInfo解析+MediaRange携带;KS路径resolveReporter带回后onChange自动seek(各单次触发),MPV原生路径经range直读ticker自动seek(相对seek到目标)。跳片尾后自然进入既有连播链路。"
}
