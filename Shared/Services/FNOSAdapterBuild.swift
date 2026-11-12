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
    static let version = "v210"

    /// 本版主要变更摘要
    static let changes = "v210:v209 真机反馈三修(KS 仍一行未动)。①mpv 选集卡真实数据:容器把兼容层 client+全分集(FNOSItem,带海报/标题/简介)注入 mpv 视图,选集卡按集号匹配显示真实缩略图(Thumb/Primary/Backdrop)+标题+两行简介,无匹配退渐变占位——数据现成零额外请求;②mpv 快速滑动根因实锤=滑动桥宿主 updateUIView 首调时未上树,爬根循环停在宿主自身(isUserInteractionEnabled=false=永不触发),且 recognizer 非 nil 后永不重挂;修=对齐 KS 模式(延迟 0.3s 挂载+爬根必须到 UIWindow 否则重试最多 3 轮+手势失效自动清理重挂);③App 图标:解包对比 v206/v209 Assets.car(2.71MB→3.88MB)证实编译产物已含 Nbeefin 图,真机不显示=tvOS 分层图标系统缓存,需删除 App+重启 Apple TV+重装。"
}
