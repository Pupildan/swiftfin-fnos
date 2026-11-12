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
    static let version = "v211"

    /// 本版主要变更摘要
    static let changes = "v211:v210 真机反馈两修(KS 仍一行未动)。①滑动真根因=window 级手势输给 tvOS 系统手势(深层视图手势先识别;KS 挂 videoView 深层所以赢,MPV 挂 window 根所以永收不到);修=手势宿主移到视频层顶层成为 hit-test 终点(isUserInteractionEnabled=true)+挂宿主自身不再爬根+simultaneous delegate+全程诊断日志(挂载/began/ended/门控快照落 9999);②选集卡一直刷新拖卡弹幕=FNOSAsyncImage 在 LazyHStack 重建时重置 @State 反复重载(v98 教训)+20+张并发解码;修=v110 终极方案:打开选集条即串行预载剧照(下载→ImageIO 急切后台解码→逐张入强引用字典),卡片 Image(uiImage:) 直渲染,零重建零闪烁零解码风暴。"
}
