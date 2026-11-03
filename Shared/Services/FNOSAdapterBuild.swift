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
    static let version = "v85"

    /// 本版主要变更摘要
    static let changes = "v85 新功能三连：①首页「继续播放」横向列表——读飞牛服务端 /Items/Resume 多端同步记录，16:9 卡+进度条，点卡按服务端进度直接续播（KS 首个时间回调 seek / mpv initialSeek 双引擎支持）；②海报墙与继续播放卡选中改为系统 .card 液态玻璃（与 Demo 同款，自绘焦点视觉拆除，focusEffectDisabled 同步移除）；③详情页信息增强——时长行追加色彩档位徽章（杜比视界 P 档/HDR10/SDR，原生 /stream 实测），题材行追加评分胶囊（IMDb/豆瓣/烂番茄，play/info 防御性解析，无数据不显示）。搁置：进入方向同行推出动画（代码内 ⏸️ 标记 + 已排除项清单）。"
}
