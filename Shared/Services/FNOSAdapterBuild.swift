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
    static let version = "v220"

    /// 本版主要变更摘要
    static let changes = "v220:弹幕渲染彻底重写=移植 ATV-Bilibili-demo 内置 DanmakuKit 的 CAAnimation 方案。旧版(v217-v219) CADisplayLink 主线程每帧改 position.x,主线程被播放器/UI 占用就掉帧抖动→v219 锁60Hz 反而更卡。新版:每条弹幕发射时挂 CABasicAnimation(position.x) 由 render server 进程独立插值,主线程零逐帧位置计算;4Hz 低频发射泵只管到点发射;播放/暂停/倍速用容器 layer.speed(Core Animation 原生时间缩放);文本异步光栅化 CGContext 先 stroke 再 fill(根治骨架字)。sync/anchor 铁律一行未动,只决定何时发射。v219:服务端直探+日志实锤:匹配成功(epId=12104),但 danmu_api 国际版 decode 端点超时→comment/{epId} 首次0条;comment?url=源站URL 绕过 decode 实测16384条。修=FNOSDanmuEpisodeRef 加 url,fetchComments 双路径(epId=0 时用 url 兜底)。不动 sync/anchor 铁律(v130),渲染帧率从请求120改锁60(tvOS 输出帧率不确定)。v218:①骨架字:CATextLayer 的 NSAttributedString 不支持负 strokeWidth 的填充语义(只画轮廓)→删除描边属性,纯实心字。②显示区域滑块失效:引擎轨道分配永远从 lane0 找起,弹幕稀疏时全挤在前几条轨道,area 拉大新增轨道用不上→改轮转分配(nextLane 指针),弹幕均匀铺满所有轨道=真正同屏更多(B站逻辑);area/字号/偏移变化时清屏按新轨道重建,调节立刻可见。③弹幕重叠:旧版 speed=(屏宽+字宽)/时长 让长弹幕更快、后发长弹幕追上前面短弹幕→统一速度(屏宽/时长),同轨间隔恒定不追尾。④两京十五日匹配不出:v217 剧名双向包含校验过严误杀别名/后缀剧→放宽为只拦集号明确矛盾(官方 isMatched 已做精确匹配),search 兜底无剧名一致时也退回全部候选按集号选,全链路加 9999 诊断日志。"
}
