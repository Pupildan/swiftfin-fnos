# HANDOVER.md — Swiftfin→飞牛影视(fnOS) tvOS 客户端 交接文档

> 仓库：`Pupildan/swiftfin-fnos`（GitHub 私有仓，CI 构建 unsigned ipa）
> 本地工作区：`C:\Users\Admin\WorkBuddy\fndanmu-tvos\build-package\swiftfin-fnos`
> 当前版本：**v210**（🆕MPV 选集卡真实数据（compat 分集缩略图/标题/简介，容器注入零请求）+ 快速滑动真根因修复（滑动桥宿主未上树挂死手势→延迟挂载+爬根校验+失效重挂）+ 图标缓存结论（Assets.car 已含新图=系统缓存问题，删 App+重启电视+重装）。v209 真机结论=**选集闪没已修 ✓（不再闪没但暴露占位卡无数据）**；前情=v208/v209 MPV 交互战役），版本标识在 `Shared/Services/FNOSAdapterBuild.swift`
> 交付物命名规则：`output/Swiftfin-FNOS-tvos-unsigned-vXX.ipa`（32MB 左右）

---

## ⚠️🚨 弹幕 sync anchor 逻辑——严禁改动（v130 严重回归教训）

**`FNOSDanmuView.swift` 的 `FNOSDanmuEngine.sync(mediaTime:)` 中 `anchorMediaTime = mediaTime`（精确等于播放器时间）是经过真机验证的唯一正确做法，绝对不要改。**

v130 我为了修「KS 轻微左右抖 + mpv 原地抖后重载」，把小漂移改成渐进校正（`anchorMediaTime = extrapolated + drift*0.15`，每次只纠 15%）。**结果灾难性变差**：KSPlayer 从轻微抖变**严重抖动+崩溃**，mpv **完全无法显示弹幕**。用户真机暴怒。

**根因**：渐进校正让 anchor 不再精确等于播放器 mediaTime，外推基点漂移→弹幕位置计算错乱→KS 抖动加剧甚至崩溃；mpv 侧 anchor 错乱导致弹幕完全不渲染。

**已在 v131（2580b49）回滚到原始 `sync()`**（硬重置 if drift>1.0 + `anchorMediaTime = mediaTime`）。**任何「渐进/平滑校正」都会破坏弹幕，严禁再动 sync 的 anchor 逻辑。**

---

## 📋 近期版本演进（v123-v166）

- **v123**：豆瓣详情页 frodo 私有 API（简介/类型/主演/导演）+ 入库按钮。**引入回归**：把详情页内容（简介等）错加到首页 Hero，破坏 Hero 焦点逻辑（右滑/右键焦点窜到继续播放）。
- **v124-v126**：首页 Hero 回滚 v122（删错加的内容区），只保留海报标题换行；新增「豆瓣热门」行（60 条=电影/电视剧/综艺 各 20，网页 JSON 端点）。
- **v127**：入库按钮背景改苹果液态玻璃 `.glassEffect`（替换 inLibrary 绿底）。
- **v128**：修豆瓣海报不显示——豆瓣 CDN 防盗链（无 Referer→418 空图），海报加载加 `Referer: movie.douban.com`。
- **v129**：豆瓣详情页接 frodo 私有 API（`/movie/{id}` id 在路径，`_api_key=0dad551...`，简介字段=intro，Swift 用 `Insecure.SHA1`）。**但 frodo 签名初版有编译错误（SHA1/upper/CharacterSet），两次修复**。
- **v130**：弹幕「渐进校正」——**严重回归**（见上方警告），已回滚。
- **v131**：修首页 Hero 焦点跳页（三按钮补全右左导航）+ 豆瓣详情页照搬 TMDB 布局（hero+简介+主演头像+评论+按标题入库）+ 豆瓣海报高清 m_ratio + 弹幕回滚。
- **v132-v166：首页焦点战役（36 版，详见文末「首页焦点战役」章节）**——轻触跳焦的定位与根除。关键节点：v139/v140 架构（Hero 进 ScrollView 随滚动滑出）；v143 诊断日志+半屏修复；v150 日志实锤根因（轻触漂移被分类为 .down 走 onDownToShelf）；v154-v157 经典模式/逐行掩码对照实验（证明任意一行可见即跳、三行全隐藏即正常）；v158 删 .down 分支（根除）；v161-v166 方案 A（推荐行跟随焦点域动态挂载，触发信号=Hero 焦点状态 onHeroFocusChanged，与 nil 计时无关——瞬态 nil 可超 1500ms，v163/v164 计时方案均败）。v152 上滑翻页/双击下键被用户否决；v146 DragGesture tvOS 不可用；v147 UIPanDetector 严重回归；v155 @AppStorage 观察者假设证伪。

- **v167-v187：详情页评论/人物弹窗 + 播放器弹幕渲染重构 + 内嵌字幕（2026-11-07~09 增量，详见文末「评论弹窗·弹幕渲染·播放器」章节）**。关键节点：v168 frodo 签名缺 `/api/v2` 修复（celebrities/reviews/photos 三通道静默 400，一个根因三症状）；v169-v171 hero 弹幕三次重构（TimelineView 逐帧=闪烁 → .position 布局=抖动 → 双拷贝 marquee+精确测宽定稿）；v172/v176/v178/v181 分区 `.focusable()` 与 `.card` 灰底反复（真根因是入库按钮 `.disabled`，v180 实锤）；v180 人物弹窗 + 入库按钮移除 `.disabled`；v183 聚焦白块真修（`FNOSBareButtonStyle`，v76 已知坑重踩）；v184 评论弹窗段落分行 + 删调试区 + 自动跳片头片尾（play_config）；v185 内嵌字幕切换 + 诊断埋点；v186 内嵌字幕渲染层 + 换集面板重做 + 弹层玻璃化（用户要求回滚，v187 仅保留字幕渲染/图标/弹层标题）。

- **v206：跳过片头片尾服务端化 + 独立设置面板（2026-11-12~13）**。协议逆向实锤（fntv-electron Go 代理 + 飞牛 Web JS 互证）：写入端点 `POST /v/api/v1/play/setConfigByItem`，body `{guid: parent_guid, skip_opening, skip_ending}`，挂剧集级 parent_guid；**skip_ending 语义=距结尾剩余秒数**（非绝对时间，v184 误判已修正为 `duration - skip_ending`）；新文件 `FNOSSkipSettingsSheet.swift`（两滑块 0~600s 玻璃面板，复刻弹幕设置）+ KS/MPV 双接线（`tv.inset.filled` 按钮 + overlay + 守卫链 + 0.5s 防抖推服务端 + 切集刷新）；详见 §2.5.1。

- **v207：片头片尾面板重做 + 服务端协议实测结论（2026-11-13）**。v206 真机反馈「不生效 + 逻辑不对」，服务端直探（test 账号 Authx 签名）实锤：**剧集链路全通**（play/info `data.parent_guid` 非空 → setConfigByItem 写 123/45 → 同集与同剧另一集回读 `play_config` 均为 123/45，剧级共享确认）；**电影无存储位**（play/info 连 `play_config` 键都缺、parent_guid 空，写自身 guid 回读仍 null——电影场景仅本端本次生效，服务端不支持）。**面板按用户规格重做**：顶部实时显示当前播放位置；聚焦行按确认键=取当前位置（片头=绝对秒/片尾=距结尾剩余秒）；左右键或触摸板滑动=±1s 微调（连按加速 ×4）；捕捉=标记此处（宿主置对应 Skipped 标志，本次播放不再自动跳——否则捕捉片尾瞬间 endingStart 恰好等于当前位置下一 tick 立即跳尾太突兀）；微调=直接改值（位置在新边界内立即 seek，保留「本集立即生效」）；0=关闭。canSync 文案区分剧集（同步到 Web/手机）与电影（仅本次播放生效）。面板打开/捕捉/推送全链路 FNOSDiag 落 9999。诊断脚本 `_tmp/probe_skip_v207.ps1`（b/c/d 三变体）。**真机反馈：跳过功能生效 ✓，但三 bug（时间读取不准/选中白色看不清/跳过后选集进度失效）→ v208。**

- **v208：v207 真机三修 + 图标（2026-11-13）**。①**面板时间读取不准**：根因=打开面板靠下一个 tick 才有 skipPanelPos，打开瞬间显示 00:00/旧值 → 立刻确认就捕捉错位置；修=按钮 action 打开时立即同步 `timemodel.currentTime/totalTime`（MPV=player.position/duration，两内核同款），打开后仍由 tick 持续刷新。②**选中效果白色看不清**：官方 `.glass` 按钮聚焦态在玻璃面板上白底白字；修=`FNOSBareButtonStyle()` + `focusEffectDisabled()` + 自绘描边（聚焦白 2.5pt/非聚焦 0.28 白 1pt，RoundedRectangle 14）——玻璃面板禁半透明白填充的老规矩继续有效。③**自动跳过后选集失效+进度条滑动失效**：头号嫌疑=KS onPlay 是 KSPlayer **后台线程**回调，播放中直接 `coordinator.seek(time:)` 有内部竞态（v87 resume seek 是起播前所以无恙）；修=自动跳过 seek 一律 `Task { @MainActor in }` 提交，并加诊断日志（触发时 timemodel 快照 + seek 提交 + 1.2s 后 cur/total 快照，两内核同款）——若 v208 真机仍复现，读 9999 日志实锤再精准修，勿盲猜。④**App 图标换 Nbeefin**：`AppIcon-dark-blue.imagestack` 双层整图铺满（Front/Back 同图，源图 2752×1536 居中裁 2560×1536→800×480/400×240，PowerShell System.Drawing），tvOS 26 系统自动处理形状；脚本 `_tmp/make_icon_v208.ps1`。tvOS target 图标名=`AppIcon-dark-blue`（pbxproj ASSETCATALOG_COMPILER_APPICON_NAME）。**首建失败两错（4800514 修）：tvOS 资产编译器要求 imagestack 最后一层（Back）完全全不透明（alpha=237 被拒 → 不透明紫底+图叠上）；MPV controlBar 的 player 是非可选参数不可 `player?.position`。**
  **真机验收（v208）：KS 三修全部完美 ✓；MPV 两 bug（选集闪没/不能快速滑动）→ v209。**

- **v209：MPV 两修（2026-11-13，KS 一行不动）**。①**选集闪一下就没了**：完整因果链=展开 → 0.15s 后 focusedChip=target → 引擎焦点移到集数卡 → focus（Control FocusState）变 nil → **ticker 250ms 焦点兜底的跳过条件只有四弹层不含 showEpisodeStrip** → 焦点被拽回 .playPause → chip 失焦 focusedChip=nil → onChange(of: focus)（newValue≠.scrubber 且 focusedChip==nil）→ showEpisodeStrip=false 关条；修=兜底跳过条件加 `|| showEpisodeStrip`。②**不能快速滑动进度条**：MPV 滑动桥 guard 把 `.began` 拦死（控制条隐藏时连唤出都不发生；KS 的 began 有 `else if !controlsVisible { revealControls() }`）+ **ticker 自动隐藏条件无 scrubActive 守卫**（KS scheduleHide 有 `!scrubActive`；MPV 拖动中 lastActivity 不更新，超 5s hideControls → 焦点被拽走 → .ended 的 commit 因 focus≠.scrubber 不执行=拖动结果丢失）；修=滑动桥结构对齐 KS（弹层让位单独判断 + began 唤出 showControls + began/changed bumpActivity）+ 自动隐藏条件加 `!scrubActive`。**真机验收（v209）：选集闪没已修 ✓（但暴露占位卡无封面无信息）；快速滑动仍不行（v209 修的不是真根因）→ v210。**

- **v210：MPV 选集真实数据 + 滑动真根因 + 图标缓存定论（2026-11-13）**。①**mpv 选集卡真实数据**：容器 `FNOSPlayerContainerView` 本身就有 compat 全分集（`episodes: [FNOSItem]`，带海报/标题/简介）——mpvLayer 构造时直接注入 `FNOSMPVPlayerView(compatClient: client, compatEpisodes: episodes)`，选集卡按集号匹配 `$0.IndexNumber == ep.number` → `compatClient.episodeStillURL`（Thumb/Primary/Backdrop 三级）+ FNOSAsyncImage 鉴权渲染 + 标题 + 两行简介；无匹配退渐变占位卡。**零额外网络请求**（KS 同款数据源），HANDOVER 待办「MPV 选集条缩略图」就此关闭。②**快速滑动真根因（v209 未命中）**：`FNOSMPVPanHostView.updateUIView` 首调时宿主 UIView **还没进 window 层级** → `mountIfNeeded` 的爬根循环 `root.superview` 为 nil 停在宿主自身 → 手势挂到 `isUserInteractionEnabled=false` 的宿主上=**永不触发**；且 `recognizer != nil` 后任何 setHost/mount 都幂等返回=**永不重挂**。KS 无此问题因为 FNOSPanBridge 是 `asyncAfter 0.5s` 后挂（视图早已上树）。修=对齐 KS：延迟 0.3s 挂载 + 爬根必须到达 UIWindow（否则重试最多 3 轮）+ 手势所在视图离开 window 自动清理重挂。③**App 图标**：解包对比 v206/v209 的 `Assets.car`（2.71MB→3.88MB）**证实编译产物已含 Nbeefin 分层图标**——真机不显示=**tvOS 分层图标系统缓存**（删除 App 重装也可能不刷）；刷新路径=**彻底删除 App → 设置里重启 Apple TV → 重装**。**通用教训：UIViewRepresentable 挂 UIKit 手势必须校验「宿主已上树+爬根到 window」且「手势视图离开 window 时自动重挂」，否则手势挂死在临时视图上永不触发。**

---

## 一、项目架构与核心文件树

### 1.1 有用的 Swift 文件（全部，共 11 个）

```
Swiftfin tvOS/App/SwiftfinApp.swift      # @main 入口，极简：直接 render FNOSRootView()，绕开 Swiftfin 原登录栈
Shared/Services/FNOSAdapterBuild.swift   # 版本号 version/changes（每次交付必须递增，用户在设置面板核对版本）
Shared/Services/FNOSAuthStore.swift      # 凭据存储(UserDefaults key="fnos.credentials.v1") + 登录请求(POST /Users/AuthenticateByName)
Shared/Services/FNOSDirectClient.swift   # 网络层核心：纯 URLSession 直连客户端 + 全部 JSON 模型(FNOSItem等, PascalCase)
Shared/Services/FNOSNativeClient.swift   # 飞牛原生 API(Authx签名)：演员/分集/播放链/多端同步
Shared/Services/FNOSTMDBClient.swift     # v111：TMDB API(trending/详情/credits, key=用户设置面板填写)
Shared/Services/FNOSBangumiClient.swift  # v115/v117：Bangumi(日历+近期注目HTML解析, 800px封面, 每日缓存)
Shared/Services/FNOSDoubanClient.swift   # v126/v129：豆瓣(网页JSON榜单+frodo私有API详情, Referer防盗链)
Shared/Services/FNOSMoviePilotClient.swift # v120：MoviePilot入库(X-API-KEY, 订阅add/lookup/列表)
Shared/Views/FNOSRootView.swift          # 根路由：已登录→FNOSMainView，未登录→FNOSLoginView
Shared/Views/FNOSLoginView.swift         # 登录界面（服务器地址/用户名/密码）
Shared/Views/FNOSMainView.swift          # 首页：Hero Banner + 媒体库海报墙 + 三行动态挂载推荐行 + 设置面板(刷新/退出/MP入库)
Shared/Views/FNOSHeroView.swift          # ATV+ 风格全屏 Hero：自绘轮播+5秒预告(AV/KS双通道)+按钮焦点翻页+onHeroFocusChanged上报
Shared/Views/FNOSPlayerView.swift        # 播放器：KSPlayer 混合引擎 + 自绘控制条 + 弹幕接线（含 FNOSPlayerContainerView；v206 片头片尾按钮/面板宿主/防抖推服务端）
Shared/Views/FNOSMPVPlayerView.swift     # mpv 引擎（MPVUI）：DoVi P5/P7 接管 + tone-mapping（v206 同款片头片尾接线）
Shared/Views/FNOSSkipSettingsSheet.swift # v206：片头片尾设置面板（玻璃风格同弹幕设置；改值交宿主即时生效+防抖推服务端，自身不落盘）
Shared/Views/FNOSTMDBDetailView.swift    # v113：TMDB 详情页(hero布局+入库状态机)
Shared/Views/FNOSBangumiDetailView.swift # v115：番剧详情页(同款布局+入库)
Shared/Views/FNOSDoubanDetailView.swift  # v126/v129：豆瓣详情页(同款布局+frodo数据+按标题入库)
Shared/Views/FNOSPipedPlayer.swift       # v123：Piped 预告片播放(LBRY HLS/MP4)
Shared/Views/FNOSDanmuView.swift         # 弹幕：FNOSDanmuEngine(匹配/拉取/时间轴) + 渲染视图(UIImage预渲染缓存)
Shared/Views/FNOSAsyncImage.swift        # 带鉴权头的异步图片组件 + 内存缓存(FNOSImageCache, NSCache 400张) + Task.detached后台解码
Shared/Views/FNOSFocusButton.swift       # 自绘焦点按钮样式（登录页/设置用）
```

**其余原 Swiftfin 源码已全部删除**（732 → 22 文件，pbxproj 用同步文件夹，删盘即生效）。工程里残留的 `Swiftfin/`、`SwiftfinMacros/`、`Translations/`、`Scripts/`、`fastlane/` 等目录对 tvOS target **不参与编译**（v12 已把 Generate Strings 脚本阶段连根拔掉）。

### 1.2 依赖现状

- **tvOS target 实际只链接一个 SPM 产品：KSPlayer**（pbxproj 中 KSPlayer/FFmpegKit 共 9 处引用）。
- `Package.resolved` 里保留的其它包（jellyfin-sdk-swift 3.3.0、Nuke、Pulse、CoreStore、Transmission、Engine 等）是工程级遗留——**tvOS target 不编译它们，但它们拖慢 -resolvePackageDependencies**。
- 关键依赖版本（锁定在 `Swiftfin.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved`）：
  - **KSPlayer 2.3.4**（kingslay/KSPlayer）+ **FFmpegKit 6.1.4**（kingslay/FFmpegKit，二进制 xcframework）
  - jellyfin-sdk-swift 3.3.0（已不再被 tvOS 代码使用）
  - swift-syntax 600.0.1（SwiftfinMacros 宏插件依赖）
- KSPlayer 2.3.4 的关键 API（换版本必查）：
  - 构造：`KSVideoPlayer(coordinator: Coordinator, url:options:)` —— **必须传 coordinator 参数**，便捷构造器会自建 Coordinator 导致外部拿不到时间/控制（v12 弹幕不动就是这个坑）
  - 时间：`coordinator.timemodel`（ControllerTimeModel，独立 ObservableObject），不是 coordinator 直属属性
  - 控制：`coordinator.isMuted`、`coordinator.isScaleAspectFill`（didSet 切 contentMode）、`coordinator.seek(time:)`、`coordinator.playerLayer?.play()`
  - 状态：`KSPlayerState.bufferFinished / readyToPlay`；回调在后台线程，改 UI 必须 `Task { @MainActor in }`
  - Header 注入：`KSOptions.avOptions["AVURLAssetHTTPHeaderFieldsKey"]`（AVPlayer 引擎）+ `KSOptions.formatContextOptions["headers"]`（"k: v\r\nk: v" 拼接，FFmpeg/KSMEPlayer 引擎）
  - 引擎选择：`KSOptions.firstPlayerType = KSMEPlayer.self（MKV）或 KSAVPlayer.self`

---

## 二、网络与鉴权（最重要）

### 2.1 基础信息

- **协议**：fnOS 的 **8005 Jellyfin/Emby 兼容层**（不是 fnOS 原生 `/v/api/v1/` + authx 签名那套！本工程走兼容层，无需签名）
- **端口**：默认 `5666`（用户登录时输入完整地址，如 `http://192.168.10.120:5666`），登录代码会自动补 `http://` 前缀、去尾部 `/`
- **JSON 风格**：PascalCase（`Id`、`Name`、`Type`、`ImageTags`、`Items` 信封），模型在 FNOSDirectClient.swift 底部

### 2.2 鉴权 Header（精确拼接，实测缺 X-Emby-Authorization 一律 400）

```
登录时（无 Token 版）:
X-Emby-Authorization: MediaBrowser Client="Swiftfin", Device="AppleTV", DeviceId="fnos-direct", Version="1.0"
Content-Type: application/json
POST {base}/Users/AuthenticateByName
body: {"Username": "...", "Pw": "..."}
响应: { "AccessToken": "...", "User": { "Id": "...", "Name": "..." } }

登录后（所有请求）:
X-Emby-Authorization: MediaBrowser Client="Swiftfin", Device="AppleTV", DeviceId="fnos-direct", Version="1.0", Token="{token}"
X-Emby-Token: {token}
```

**图片/媒体直链请求额外要求**：`FNOSDirectClient.mediaHeaders`（在 FNOSAsyncImage.swift 的扩展里）返回三件套：
`X-Emby-Authorization` + `Authorization`（同一个值）+ `X-Emby-Token`。海报和视频直链都建议全带。

### 2.3 已跑通的端点清单

| 用途 | 端点 | 要点 |
|---|---|---|
| 媒体库列表 | GET `Users/{uid}/Views` | 返回 Items[]（FNOSLibrary） |
| 条目列表 | GET `Users/{uid}/Items?ParentId={libId}&Recursive=true&Limit=100&SortBy=SortName&Fields=PrimaryImageAspectRatio,ProductionYear,Overview` | |
| 播放源 | POST `Items/{itemId}/PlaybackInfo?UserId={uid}` | **必须先取真实 MediaSourceId**，stream 传空值一律 400 |
| 播放直链 | GET `Videos/{itemId}/stream?static=true&MediaSourceId={msid}&api_key={token}` | MKV 等容器原样返回 |
| 海报 | GET `Items/{itemId}/Images/Primary?maxWidth=400&quality=85&tag={ImageTags.Primary}` | **必须带 tag 参数，否则 404** |
| Hero 大图 | GET `Items/{itemId}/Images/Backdrop?maxWidth=1920&quality=90&tag={ImageTags.Backdrop}` | 同上 |

### 2.4 弹幕服务（danmu_api，与飞牛无关的独立服务）

- Base URL：`http://192.168.10.120:9321/199780jjj`（写死在 FNOSDanmuEngine.defaultBaseURL）
- 匹配：POST `/api/v2/match`，body `{"fileName": "标题"}` → episodeId
- 搜索：GET `/api/v2/search/episodes?anime={title}`
- 弹幕：GET `/api/v2/comment/{episodeId}?withRelated=true&chConvert=1`
- 时间轴绑定：`danmuEngine.sync(mediaTime:)` 由播放器进度驱动（FNOSPlayerView 里观察 `coordinator.timemodel.currentTime`）；倍速时 `setRate()`；暂停 `setRate(0)`
- 渲染优化：每条弹幕 UIImage 预渲染 + NSCache(600)，字号/透明度/速度存 @AppStorage(`fnos.danmu.*`)

### 2.5 外部内容源端点（v111-v130 新增，全部实测）

> **v206 跳过片头片尾（服务端同步，挖自飞牛 Web 播放器 `/v/assets` JS，勿再猜语义）**
> - 读：`POST /v/api/v1/play/info` → `data.play_config.{skip_opening,skip_ending}`，另取 `data.parent_guid`（配置粒度 = 整剧/整季）
> - 写：`POST /v/api/v1/play/setConfigByItem` body `{"guid": <parent_guid>, "skip_opening": N, "skip_ending": N}`，`code==0` 为成功
> - **语义**：`skip_opening` = 片头结束**绝对秒数**；`skip_ending` = **距结尾剩余秒数**（片尾开始点 = 总时长 − skip_ending）。
>   证据：Web `allowSkipEnding` 判 `duration - opening - ending >= 5`；设置面板 ending 行显示 remainingTime、opening 行显示 currentTime；本地参考 `fnos_tv_danmu` 同口径。
> - **合法区间**：两端 `0 ~ 600`（`maxTotalMinutes=10`），`0` = 该端不跳过，步进 5s。Web 端改设置后 50ms 防抖自动保存。
> - ⚠️ v184 曾把 `skip_ending` 当绝对时间点（`currentTime >= se`），服务端一旦有值会在片头结束处就跳片尾；v206 已在 KS / MPV 两处改为 `时长 − se` 判定。

### 2.5.1 v206/v207 落地状态（接手必读）

**✅ v206 已交付**：commit `2a61d46` push main（2026-11-13）→ CI success（run 43255567700）→ `output/Swiftfin-FNOS-tvos-unsigned-v206.ipa`（32.6MB）。真机反馈=「不生效 + 面板逻辑不对（盲滑块不知道设多少秒）」→ v207 重做。

**🚨 v207 服务端协议实测结论（2026-11-13 直探，勿再猜测）**：
- **剧集**：`play/info`（集 guid）→ `data.parent_guid` **非空**（=剧级条目 guid）；`setConfigByItem {guid: parent_guid, skip_opening:123, skip_ending:45}` → code=0；回读**同集与同剧另一集** `play_config` 均为 123/45 → **多端同步链路完整可用**。
- **电影**：`play/info` `parent_guid` 为空且**无 `play_config` 键**；写自身 guid 回读仍 null → **电影在服务端无存储位**，只能本端本次生效（面板 canSync=false 文案已说明）。

落地内容：

| 位置 | 内容 |
|---|---|
| `FNOSNativeClient.swift` | `maxSkipSeconds = 600`；`MediaRange.parentGUID`；`playInfo` 返回值带 `parent_guid`；新增 `setSkipConfig(parentGUID:skipOpening:skipEnding:) async -> Bool` |
| `FNOSPlayerView.swift:869` | **修正**：`endingStart = total - se` 再判 `currentTime >= endingStart`（原按绝对点，是 bug） |
| `FNOSMPVPlayerView.swift:918` | **同上修正**：`endingStart = dur - se` |
| `FNOSAdapterBuild.swift` | version → v206 |
| `HANDOVER.md` | 本节（协议结论 + 语义证据） |

v206 设置面板（已接线，待真机验证）：

| 位置 | 内容 |
|---|---|
| `FNOSSkipSettingsSheet.swift`（新文件） | 独立「片头片尾」玻璃面板：两行自绘滑块（0~600s、步进 5s、v194 连按加速），风格 1:1 复刻 `FNOSDanmuSettingsSheet`；面板不落本地存储——改值经 `onChange` 交宿主 |
| `FNOSPlayerView.swift` | 新增 `.skipSettings` Control + `tv.inset.filled` 按钮（danmuSettings 旁）；`skipSettingsPresented` 弹层分支进 `isSheetPresented` overlay；`closeSheet()` 关闭；`resolveReporter()` 存 `reporterParentGUID`；`commitSkipSettings()`=本端立即生效 + 0.5s 防抖 `setSkipConfig` 推服务端 |
| `FNOSMPVPlayerView.swift` | 同款按钮/弹层/`commitSkipSettings`（用 `native` + `parentGUID` @State，init 从 `range.parentGUID` 初始化）；`skipOpening/skipEnding` 改 `@State`（面板改值 tick 立即生效）；切集 `switchEpisode` 刷新 parentGUID 并重置 `introSkipped/endingSkipped`；守卫链（pan/exit/自动隐藏/焦点兜底）全部纳入 `showSkipSettings`；音轨/字幕按钮互斥关掉本弹层 |
| `FNOSPlayerView.swift:250` | `FNOSPanelPanHostView` 去掉 `private`——新面板复用触摸板滑动桥 |

真机验证清单（出包后逐项）：

1. 播放剧集 → 控制条出现「片头片尾」按钮（tv 图标）→ 打开面板焦点自动落「跳过片头」行。
2. 设 90/60 → **本集立即生效**（面板不关也生效）→ 退出重进 → 服务端值仍是 90/60。
3. 另一端（Web/手机）看到同样值；Web 端改值 → tvOS 重进播放后取到新值。
4. 改 0（关闭）→ 两端都不再跳。
5. **连播回归**：片尾设 ≥5s 播完一集，确认自动连播仍正常（seek 终点贴近 1.5s 窗口的理论边界，实测确认）。
6. 面板内触摸板滑动/连按左右加速调节流畅；Menu 键关闭；焦点不丢。

未落地（后续）：

1. **剧集级/全局开关**：Web 端无 "仅本集" 概念，本客户端也别加；每部剧独立配置。
2. KS 引擎直连 mpv 的引擎切换（`probeProfile`/`switchToMPV`）路径：`skipOpening/skipEnding` 由
   `mpvRange` 带入 MPV 面板初值，但 KS 阶段改过的值不会带过去（面板重开会显示服务端值）——影响极小，暂不处理。

换集链路（已接线）：MPV `switchEpisode` 刷新 parentGUID + 重置 `introSkipped/endingSkipped`（新集 play_config
随 `mediaRange(itemGUID:)` 带回）；KS 侧换集走「关播→重开」既有链路，`resolveReporter` 重取 play_config。

| 服务 | 端点要点 |
|---|---|
| TMDB | GET `api.themoviedb.org/3/trending/all/day` + `/movie|tv/{id}?append_to_response=credits`；key 用户在设置面板填（`fnos.tmdb.apikey`） |
| Bangumi | 日历 GET `api.bgm.tv/calendar`；近期注目=HTML 解析 `bangumi.tv/anime/browser?sort=trends`（需浏览器 UA，正则 `li[id=item_XXX]`，封面 /r/400/→/r/800/）；每日缓存存 @AppStorage JSON（v155 起缓存键**直读直写 UserDefaults，不再用 @AppStorage**——其 KVO 观察者被实锤为 v117 轻触跳焦引入者） |
| 豆瓣榜单 | GET `movie.douban.com/j/search_subjects?type={movie\|tv}&tag={热门\|综艺}&page_limit=20`（需 UA+Referer `movie.douban.com`，海报也带 Referer 否则 418） |
| 豆瓣详情 | frodo 私有 API `frodo.douban.com/api/v2/movie|tv/{id}`，签名=base64(HMAC-SHA1(secret,"GET&{quote(path,safe='')} &{ts}"))，secret=`bf7dddc7c9cfe6f7`，`_api_key=0dad551ec0f84ed02907ff5c42e8ec70`，ts=%Y%m%d，必带 os_rom=android，简介字段=intro |
| MoviePilot 入库 | Base `http://192.168.10.120:30033`，头 `X-API-KEY`；POST `/api/v1/subscribe/` body `{"type","name","year","tmdbid"|"bangumiid"}`（MP 把 bangumiid 转存为 tmdbid，查询按 name 匹配）；key 存用户设置面板 |

### 2.6 多端同步（飞牛原生协议）

- `POST /v/api/v1/play/record {media_guid,item_guid,ts}`（实测 200 落库）+ `GET /v/api/v1/play/list`（继续播放列表，时长为秒=唯一可靠时长源）
- 协议挖自飞牛 Web 播放器 JS（8005 端口 /v/assets/*.js）；兼容层 /Sessions/Playing* 是 204 空壳不可用

---

## 三、已实现的核心功能与 UI 状态

### 3.1 播放器（FNOSPlayerView，当前稳定，v16 基线后基本未动）

- `KSVideoPlayer(coordinator:url:options:)` 裸视图 + **完全自绘控制条**（无系统 UI）
- 引擎按容器分流：MKV→KSMEPlayer(FFmpeg)，其余→KSAVPlayer；`KSOptions.firstPlayerType` 全局设置
- Header 双通道注入（见 1.2）；准备流程：PlaybackInfo 取 MediaSourceId → streamURL → load 弹幕
- 控制条：fnosGlass 背景=`Color.black.opacity(0.4)`（**禁 Material/glassEffect**，焦点高亮板问题）；快进快退梯子 `[10,30,60,120]s`（间隔<0.2s 加档，只刷进度条+时间文本，无弹窗）；倍速 0.5/1.0/1.5/2.0；弹幕开关在控制条上；3 秒无操作自动隐藏
- ⚠️ 状态：v31/v32 未触碰播放器。已知小瑕疵：按钮选中高亮偶发圆角矩形（tvOS 焦点引擎对 .card 样式的系统行为，v18-v21 五次修复均失败后用户接受回退）

### 3.2 Hero Banner（FNOSHeroView，v31 定稿方案）

- **纯原生焦点方案（用户拍板）**：
  - `enum HeroButton { play, plus, detail }` + 单一 `@FocusState focusedButton`
  - 按钮行 `.defaultFocus($focusedButton, .play)` + onAppear 120ms 后程序化再压一次（防左上角设置按钮抢焦点）
  - **播放按钮** onMoveCommand `.left` → `currentIndex -= 1`（上一张）
  - **详情按钮** onMoveCommand `.right` → `currentIndex += 1`（下一张）
  - 翻页后 `focusedButton` 强制回写原按钮；**上键 default:break 不响应**（不许跳设置）；**下键** → onDownToShelf 回调（主视图 ScrollViewReader.scrollTo + 450ms 后焦点落首卡）
- 轮播渲染：自绘 `HStack(全页宽) + offset(-currentIndex * 页宽)`（**弃用 TabView**，页控制器会安全区内缩出黑边）；海报 106% 过扫描 + clipped 防四边黑边
- 数据：`heroSnapshot: [FNOSItem]` **@State 快照**，只在 bootstrap/刷新时生成（绝不在 body 求值中 shuffle）；按 **Id 去重**（同一电影可能出现在多个库视图，重复 Id 破坏 ForEach 恒等）
- 智能预告：`.task(id: currentIndex)` 等待 **5 秒** → 正片中间开始播 30 秒静音预告：
  - mp4/mov/m4v/m3u8 → 独立 AVPlayer（AVURLAssetHTTPHeaderFieldsKey 注头，seek 到 total/2）
  - MKV → **第二个独立 KSPlayer 实例**（新 Coordinator、静音、bufferFinished 单次触发 seek + `isScaleAspectFill=true`，80ms 后补设一次防首帧原比例闪现）
  - 防闪退：onStateChanged 只认 bufferFinished 单次 + `Task{@MainActor}` + 双重守卫
- 已知未解决问题：**部分电影 Hero 图文不匹配**——客户端侧已排除重复 Id/渲染竞态/缓存（v32 刷新会清全部缓存+强制重抽），高度怀疑是**飞牛刮削的 Backdrop 挂错电影**（数据问题）；判别法：设置→刷新媒体库，若换了一批新电影仍错位即是刮削数据问题，需在飞牛后台重新识别

### 3.3 首页（FNOSMainView，v166 架构）

- 结构：GeometryReader 全屏 → ZStack{ 黑底 / ScrollViewReader{ ScrollView{ Hero(全屏高) + VStack[继续播放 + 媒体库行 + 三行推荐(动态挂载)] } } / 左上角设置按钮 }
- **三行推荐（豆瓣/TMDB/番剧）动态挂载（方案A，v161-v166）**：焦点在 Hero 按钮上 = 不挂载（首页=纯 v98 结构，真机实验证实轻触不跳/翻页/下键全正常）；触发信号 = Hero 的 `onHeroFocusChanged` 回调（focusedButton onChange 上报），**与 shelfCardFocused 的 nil 计时无关**（跨行移动的瞬态 nil 可持续 1500ms+，LazyHStack 滚动曝光延迟，任何计时方案误判——v163 400ms/v164 1500ms 均败）；回 Hero = 卸载 + 整页滚回顶部（卸载/挂载都在视口外，无闪烁）；详情浏览期间保持挂载（关闭后焦点可归还原卡）
- 下键入墙 = 引擎原生空间移动（`.down` 分支已删——v150 日志实锤：轻触漂移被分类为 .down 走 onDownToShelf 跳焦；经典模式实验：三行全隐藏即不跳）+ onDownToShelf 的 scrollTo shelf-top + 450ms 焦点落首卡
- 媒体库墙：**外层必须用非懒 VStack**（LazyVStack 屏外行不实例化，焦点引擎无落点——v30 下键失效的根因）；行内 LazyHStack 卡片 `.buttonStyle(.card)` + 每张卡 `.focused($shelfCardFocused, equals: item.Id)`
- 三行数据拉取**常开**（bootstrap，不受任何开关门控——v157 掩码门控拉取导致停在隐藏档重启后数据丢失、行永远回不来）；数据常驻内存，挂载瞬时显示
- Hero 抽选：只抓 `type=="Movie"`，每日一次存 UserDefaults(`fnos.hero.date`/`fnos.hero.ids`)；设置里"刷新媒体库"= 清 heroDate 强制重抽 + 清 FNOSImageCache + URLCache
- 设置面板 `FNOSHomeSettingsView`（sheet）：刷新媒体库 / 退出登录 / TMDB key / MoviePilot 入库地址+密钥 / 版本信息
- **已知硬限制**：右滑向前翻页不可靠——引擎把 .right 劫持为空间跳（窜到右下卡片）+ 触控板纵向漂移污染 .down；硬件方案 = 修右物理键 / Gen1 遥控（实体方向键零漂移）
- **已否决勿重试清单**：focusEffectDisabled 增删 / hero .focusSection / UIFocusGuide / 折叠 / 62% 压缩 / ZStack 死背景 / scrollDisabled / 容器级 onMoveCommand / DragGesture(tvOS 不可用) / UIPan 覆盖层 / @AppStorage 观察者假设 / 上滑翻页重映射 / 双击下键守卫 / nil 计时卸载

---

## 四、构建与发布流程（CI/CD）

### 4.1 流程概览（`.github/workflows/build-tvos.yml`）

- **公开仓库 GitHub Actions 免费编译**（macOS runner `xcode-27`），push main 或手动触发
- 步骤：checkout → 允许宏（`defaults write com.apple.dt.Xcode IDESkipMacroFingerprintValidation -bool YES`，SwiftfinMacros 本地宏包必需）→ 恢复缓存 → resolve 依赖 → xcodebuild → 打包 ipa → 存缓存 → 传 artifact
- **缓存优化**：`actions/cache` 缓存整个 `build/`（DerivedData + clonedSourcePackages 都在 -derivedDataPath build 下）；key=`tvos-build-{hash(Package.resolved)}`，restore-keys 兜底；resolve 前只删 `build/XCBuildData`（清过期构建计划，保留已下载依赖）；**失败也存缓存**（`if: always()`）
- 打包：Release-appletvos 找 .app → `ipa/Payload/` → zip 成 unsigned ipa → artifact `Swiftfin-FNOS-tvos-unsigned`（保留 30 天）

### 4.2 xcodebuild 参数（原样照抄）

```bash
# 依赖解析
xcodebuild -resolvePackageDependencies -project Swiftfin.xcodeproj -scheme "Swiftfin tvOS" -derivedDataPath build

# 未签名编译
xcodebuild -project Swiftfin.xcodeproj -scheme "Swiftfin tvOS" \
  -configuration Release -sdk appletvos -derivedDataPath build \
  -disableAutomaticPackageResolution \
  SWIFT_VERSION=5.0 CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY="" build
```

- `-disableAutomaticPackageResolution`：按 Package.resolved 锁定版本解析，**禁止省略**（省略会触发依赖树重算/死锁）
- Package.resolved 死锁修复经验：依赖变更时只改 pbxproj 引用会导致 resolved 与工程不一致 → 保证 resolved 与 target 引用一致，或删掉 resolved 重新 resolve 一次再提交
- 交付脚本（会话内自动执行）：GitHub API 下载 artifact → 重命名 `Swiftfin-FNOS-tvos-unsigned-vXX.ipa` → 放 `output/` → present_files 交付。PAT 在 git remote URL 里（`x-access-token:github_pat_...`），API 轮询/下载用同一个 token
- 构建耗时约 4-7 分钟；自动化监控最小间隔被平台限制为 1 小时，用户催促时会话内 30s 轮询

---

## 五、【避坑指南】严禁新 AI 触碰的雷区（血泪清单）

### 架构红线
1. **`FNOSDirectClient.swift` 网络层禁改**——已跑通的最简 URLSession 实现，任何"优化"都可能引入 400/401。fnOS 兼容层的怪癖：缺 `X-Emby-Authorization`→400、`MediaSourceId` 空→400、图片缺 `tag`→404。
2. **不要动 KSPlayer 调用方式**：必须用 `coordinator:` 参数构造器；时间在 `coordinator.timemodel`；KS 回调在后台线程，碰 UI 必须 MainActor。
3. **tvOS target 不要加新 SPM 依赖**，不要改 Package.swift——会触发依赖树重算，CI 缓存失效 + 可能死锁。

### UI 焦点（v18-v31 用 14 个版本换来的教训）
4. **绝对不要用 UIPanGestureRecognizer/全局手势拦截做焦点导航**——与 tvOS 焦点引擎打架，v26-v28 全线失败，v31 已全部删除，翻页走按钮 `onMoveCommand`（用户拍板的最终方案）。
5. **绝对不要用 Material/glassEffect/ultraThinMaterial**——焦点引擎检测到材质会画系统高亮板（圆角矩形），`focusEffectDisabled` 也禁不干净；毛玻璃一律 `Color.black.opacity(0.4)` + scaleEffect 自绘。
6. **Bool @FocusState 多视图绑定会歧义命中屏幕外视图**——用枚举 FocusState（如 HeroButton）或每视图唯一 equals 值。
7. **屏幕外可聚焦元素会抢 defaultFocus / 焦点乱跳**——初始焦点用 defaultFocus + onAppear 延时程序化双保险。
8. **懒容器（LazyVStack）屏外视图不存在，焦点引擎找不到落点**——需要焦点进入的列表外层用普通 VStack，进入后再由代码 scrollTo+延时设焦点。
9. **onMoveCommand 挂在按钮上处理某个方向时，其它方向留给 default:break**（焦点引擎先仲裁，能移动焦点时命令不会到 handler）。
10. **一次性只改一个 UI 问题**——v17 详情页大改被整体回滚；v19 夹带改动引入 X 图标。用户原话："实现的功能绝对不能碰"。

### 数据渲染
11. **ForEach 的 id 严禁重复**——同一电影出现在多个库视图会产生重复 Id，破坏恒等导致图文错配；入口必须去重。
12. **随机/洗牌数据绝不能放在计算属性里**（body 每次求值都重洗）——用 @State 快照，只在加载/刷新时赋值。
13. **TabView(.page) 在 tvOS 全屏页有安全区内缩黑边**——自绘 HStack+offset+106% 过扫描替代。
14. **KSPlayer 第二实例的 onStateChanged 在后台线程且可能重复触发**——单次守卫 + MainActor，否则闪退（v25 血案）。
15. **Generate Strings 类脚本阶段已彻底拔除**（pbxproj 的 PBXShellScriptBuildPhase + Scripts/Translations），不要恢复。

### 工作流
16. 每次交付：改代码 → bump `FNOSAdapterBuild.version` → commit → push → 轮询 CI → 下载 artifact 重命名交付，**无论成败都要主动汇报**。
17. 构建失败只修 error 不重构；日志看 Actions run 的 build step（历史日志在 `build-package/ci-run*.log`）。
18. 历史交付包全在 `fndanmu-tvos/output/`，回退基线：tag `v16-baseline`（4b920f0）。

---

# 首页焦点战役（v131→v166，36 版）——已解决，最终方案与全部教训

## 战役结果（v166 真机验证通过）

轻触不跳 / 左右滑翻页 / 单次下键进海报墙 / ⬆️回Hero卸载滚顶 / 推荐行可导航。
最终架构 = **v98 Hero 原文件（只删 .down→onDownToShelf 分支）+ 方案A动态挂载 + onHeroFocusChanged 触发信号**。

## 当前首页焦点架构（v166）

1. **Hero = v98 原文件**：focusEffectDisabled + .left→pagePrevious/.right→pageNext + **.down 分支已删**（轻触跳焦路径）。
2. **三行推荐（豆瓣/TMDB/番剧）动态挂载**：焦点在 Hero 按钮上 = 不挂载（首页 = 纯 v98 结构）；焦点进海报墙 = 挂载；回 Hero = 卸载 + 整页滚回顶部。
3. **挂载/卸载触发信号 = Hero 的 onHeroFocusChanged 回调**（focusedButton 的 onChange 上报 true/false）——**与 shelfCardFocused 的 nil 计时完全无关**（跨行移动的瞬态 nil 可持续 1500ms+，任何计时方案都会误判）。
4. onDownToShelf 挂载保留（双保险，幂等）；三行数据拉取常开与挂载无关（数据常驻，挂载瞬时显示）。
5. 设置面板的「内容行排查」循环器与守卫等全部临时机制已移除。

## 跳焦根因（最终版）

轻触跳焦 = **轻触漂移被引擎分类为 .down + v98 接线的 .down→onDownToShelf 把焦点送回继续播放首卡**。
- 三行推荐的存在是「引擎投递该命令」的条件（经典模式实验证实：三行全隐藏时引擎无目标不投递）。
- 任何单行都不是特异因（逐行掩码实验证实：隐藏任意一行仍跳）。
- v100/v116 ipa 不跳而新构建跳的原因未在代码层定位（疑似 tvOS 引擎行为差异/测试手势差异）——最终解法是**复刻 v100 的行为结构**（删 .down 分支 + Hero 态无三行）而非解释差异。

## 踩坑清单（36 版的失败分类，按消耗排序）

1. **无实机证据就发明机制（约 12 版）**：守卫/双击下键/换通道/scrollDisabled/容器级 onMoveCommand/UIFocusGuide 重定向——引擎是黑盒，猜 10 次不如测 1 次。
2. **把视图结构当变量穷举（8 版 v134-v141）**：事后 `git diff v98..HEAD` 证明外壳焦点 API 面与 v98 完全一致——结构从来不是变量，八版全部无效。
3. **两次未验证的对比推断各误导一轮**：v133 删 focusEffectDisabled（"select 失灵"理论）/ v142 恢复它（"v122 对比"）——都没有 A/B 支撑。
4. **诊断日志加得太晚（最大教训）**：v143 才挂日志，v150 日志一出就实锤根因（轻触 onDownToShelf 连发 3 次）。若 v131 挂日志省约 19 版。
5. **擅自改操作逻辑**：v152 上滑翻页 + 双击下键被用户打回——交互变化必须先经用户确认。
6. **二分数据过度定罪**：v116/v117 二分只能缩小范围；据此定罪 @AppStorage（v155）被证伪。
7. **tvOS 硬限制**：DragGesture 不可用（编译错）；.right 从不投递（引擎空间跳劫持 + 触控板纵向漂移污染 .down）→ 右滑前翻 = 硬件层限制（修右物理键/Gen1 遥控）。
8. **惰性实现延迟**：LazyHStack 跨行移动的瞬态 nil 可持续 1500ms+——任何基于 nil 计时的机制都会误判（v163 400ms/v164 1500ms 均失败）→ 触发信号必须换源（v166 焦点状态）。
9. **PowerShell 拼接中文文件必损坏**（两次截断 MainView）——中文编辑一律用 Edit 工具，Read 后 Edit。
10. **掩码/开关门控拉取会丢数据**：停在隐藏档重启 → 拉取被跳过 → 行永远回不来。拉取常开，掩码只控显示。

## 未来可能出现的问题（预案）

- 行闪没 + 焦点跳回首卡复发 = 瞬态 nil 窗口问题再现 → 先查 onHeroFocusChanged 触发链是否被绕过（不应再有 nil 计时逻辑）。
- 新增全屏呈现态（新播放器/新面板）忘加卸载守卫 → 对应状态退出后推荐行消失 → 把新状态加进 onChange 卸载守卫（当前已含 detailItem/flight/playbackTarget/seriesItem）。
- 快速上下往返掉帧 = 挂载/卸载 70+ 控件的布局尖峰 → 挂载/卸载加 0.2s 防抖。
- 首屏无推荐内容 = 方案 A 的设计代价（用户已确认接受），不是 bug。
- 右滑前翻不可靠 = 硬件限制；若右物理键修好，v98 的 .right→pageNext 接线即可恢复前翻。
- 推荐行空白 = 查数据层（fetch 失败/cache 空），不是挂载逻辑。
- 完整症状→原因→解法对照表（10 项）见记忆文件 plan-a-dynamic-mount-known-issues。

---

# 评论弹窗·弹幕渲染·播放器（v167-v187）——铁律、踩坑与未解问题

## 焦点规则（终版，v180/v183 实锤）
1. **`.disabled()` 焦点陷阱**：正在聚焦的视图被 `.disabled()` → 焦点强制释放，引擎不会滚动找重落点 → 焦点 nil → 方向键全死。入库按钮是详情页 Hero 唯一可聚焦元素——v180 起已移除其 `.disabled`（action 有 `guard libState == .idle` 幂等守卫）。**永远不要 `.disabled()` 一个可能正在聚焦的元素**，状态用文案表达。
2. **分区外层 `.focusable()`**：含 Button 的分区不带（焦点落分区上进不了内部按钮）；纯展示分区保留。豆瓣评论分区（无包裹）是金标准。注意：v176/v178 的反复是因为当时误判了已入库下键失效的根因（真因=入库按钮 .disabled）。
3. **聚焦白块**：`.plain`/`.borderless` 在 ScrollView 内仍画系统焦点板（白圆角框），`focusEffectDisabled` 压不住——**自制可聚焦按钮一律 `FNOSBareButtonStyle()`（定义在 FNOSMainView.swift:2122）** + 自绘聚焦视觉（描边/缩放/白底黑字）。
4. **tvOS 26 `.buttonStyle(.card)` 常驻渲染玻璃底**：内容不铺满按钮就露灰底（海报墙不露是因为海报铺满按钮）。

## 弹幕渲染（v169-v174 血战定稿）
- **闪烁/抖动根因**：TimelineView 逐帧重建（Canvas 或 Text.position 都犯过）；`.position()` 是布局属性每帧改触发宿主重布局。定稿 = `.offset()` 纯 transform + `.fixedSize()` 锁行宽。
- **hero 评论弹幕（FNOSReviewDanmaku）**：每泳道「文本链·双拷贝」+ repeatForever 线性 offset；链宽用 NSString+实际字体精确测宽（粗估会让循环复位跳变）；禁 preference 测宽（真机不触发→静止）与 drawingGroup。
- **播放器弹幕（FNOSDanmuView）**：KS+MPV 共用；弃 Canvas 逐帧重绘，原生 Text.offset；**引擎时间轴/锚点零改动（sync anchor 铁律未碰）**。残留极轻微停顿未根治（需录屏定位）。

## 弹窗组件
- **FNOSReviewPopupSheet（豆瓣评论）**：内容按自然段落分行（每段 focusable，**禁 110 字硬切**——句中截断被否决）；影评全文走 `/review/{rid}`（列表 abstract 是摘要截断），按影评 id 缓存；关闭按钮已删（Menu 关闭，内容行可聚焦保证 Menu 路由）。
- **FNOSPersonPopupSheet（人物弹窗）**：豆瓣 frodo `/celebrity/{id}` extra.info 键值对（性别/生日/出生地/中英文名/家人/IMDb；**该端点无简介正文**）；TMDB personDetail（biography+生日+出生地）；番剧 /v0/persons、/v0/characters summary。
- **播放器弹层（FNOSAudioTracksSheet）**：title 参数区分音轨/字幕；字幕图标 character.textbox。
- **弹窗关闭按钮删除模式**：内容行可聚焦 → Menu 正确路由到弹窗 onExitCommand。

## 内嵌字幕（未完成——v186 方案被回滚待重做）
- **真因**：裸 KSVideoPlayer 不含 KSPlayer 字幕 UI——`coordinator.subtitleModel`（public）解码了内嵌字幕但无人渲染。
- **v186 方案（已回滚）**：进度 tick 读 `subtitleModel.parts`（`text` 是 NSAttributedString，**按字幕原始信息显示、禁加阴影/字号**）叠加 overlay 渲染层；`select(track:)` 后 MEPlayer 置 isSeek 需小 seek 刷新。
- **MPV 路径**字幕由 mpv 自渲染（v119 tone-mapping 已修），无需处理。

## 自动跳过片头/片尾（✅ v206 服务端化 + v207 面板重做——服务端配置多端同步，实测剧集链路全通）
- fnOS `play/info` 原生携带 `play_config.skip_opening` / `skip_ending`。v206 协议逆向实锤（fntv-electron Go 代理 `api.go:202` 端点 + 飞牛 Web 播放器 JS 消费端语义互证，**勿再猜测**）：
  - **写入端点**：`POST /v/api/v1/play/setConfigByItem`，body `{"guid": <parent_guid>, "skip_opening": N, "skip_ending": N}`，`code==0` 成功；Web 端改后 50ms 防抖自动保存。
  - **语义**：`skip_opening`=片头结束**绝对秒**；`skip_ending`=**距结尾剩余秒数**（片尾开始点 = 总时长 − skip_ending）；两值 0~600（0=关闭）；配置挂**剧集级 parent_guid**（多端共享，换客户端无需重设）。
  - ⚠️ v184 曾把 `skip_ending` 当绝对时间点判 `currentTime >= se`——服务端有值时会在片头结束处就跳片尾；v206 已修正为 `endingStart = 时长 - se`（KS/MPV 两处）。
- **v206 落地**（详见 §2.5.1）：服务层 `setSkipConfig(parentGUID:skipOpening:skipEnding:)` + `MediaRange.parentGUID`；新文件 `FNOSSkipSettingsSheet.swift`（两滑块玻璃面板，风格复刻弹幕设置）；KS/MPV 控制条新增 `tv.inset.filled` 按钮；改值=本端立即生效 + 0.5s 防抖推服务端（对齐 Web 语义）；MPV 切集刷新 parentGUID 并重置单次触发标记。
- 真机验证清单在 §2.5.1（设 90/60 → 重进生效 → Web 端可见 → 改 0 关闭 → 连播回归）。

## 其他新增结论
- **豆瓣 frodo 签名必须含 /api/v2**（v168）：celebrities/reviews/photos/celebrity 等全部 frodo GET 通道；frodoGet 统一走 frodoGetAny（数组根响应用它）。
- **编译坑**（本轮多次首推失败）：成员初始化器实参顺序=声明顺序；嵌套类型跨视图引用需全限定（FNOSDanmuEngine.ActiveComment）；非可选属性不能 if let；fullScreenCover 内容闭包里的 .task 引用 item ✓ 但闭包外引用不到。
- **8 线程分段并行下载**：`_tmp/v167_probe/get_v186_mt.ps1`（改 run id + ipa 名复用）；必须分段校验+顺序补拉（网络抖动会短段）；Start-Process ArgumentList 带空格参数要手动加引号；勿用 -C - 配 Range。
- **TMDB infoSection 死代码**（未被 body 引用，内含重复演员行）——已确认待清理。
- **debugLines 管道**：FNOSItemDetailView 的调试区 UI 已删（v184），debugLines 收集仍后台运行（不可见）。
- **git 整包回滚**：reset --hard + force push（v179/v186 两次），被回滚的提交仍在 reflog/历史可寻。

## v188-v205：诊断通道·滑块手感·MPV 1:1·屏保·弹幕颜色（2026-11-09~10，⚠️最新铁律区）

### 版本流水（摘要）
- **v188**：选集条 4 大卡重做 + **诊断通道断裂修复**——FNOSDiag 只 print 从不 POST 到 9999，播放侧诊断自埋点起全断；v188 并入 FNOSDiagLog.send（教训见铁律 8）
- **v189**：播放器三弹窗 .sheet → 播放器内 overlay（tvOS .sheet 系统压暗+玻璃只折射 sheet 内暗背景=死灰板）；内嵌字幕弃 ASS 描边样式（渲染=线条骨架字）改软件默认字体 40pt 白
- **v190**：弹幕设置四项无极滑块（自绘 focusable+onMoveCommand，系统 Slider 焦点不可靠老坑）+ 弹幕显示区域（引擎 laneCount 动态化，maxLanePool 20 定长池，默认 30%）+ Hero 剧集解禁（抽选池 Movie+Series；剧集预告解析第一集随机 30s=15%-75% 起点；播放键对剧集=开剧集详情页）
- **v191**：滑块支持触摸板滑动（根挂载 pan 桥，仅水平且聚焦滑块时消费）+ 删完成按钮（Menu 关）+ 隐藏底部弹幕开关(hideBottom，引擎弃 mode4) + **字幕保护区死规则（泳道封顶屏高-260+底部固定弹幕上移 height-290+区域滑块上限 75%）** + **MPV 与 KS 1:1 对齐**（控制条 KS 布局/倍速 0.5-2.0/三大玻璃弹窗共用=FNOSTrackOption 中性模型/4 大卡选集条/续播选择窗 3s/进度梯子 10-30-60-120/FNOSMPVPanCoordinator 滑动拖动/字幕 40pt 统一；🐛修 mpv ticker 弹幕倍速硬编码 1.0；mpv 诊断按钮已删=严格 1:1）
- **v192**：mpv 色彩修正（hable 偏亮+饱和色发灰 → tone-mapping 换 bt.2390 EETF+色域映射 clip→per-channel）
- **v193**：滑块滑动不跟手修复=滑动桥改每实例协调器直连面板绑定（旧桥写 UserDefaults 靠 @AppStorage 回读不即时）；mpv 弹窗焦点修复=ticker 250ms 兜底在弹层打开时跳过+关闭弹层回对应按钮(sheetReturnFocus)
- **v194**：滑块步进加大+连按加速；🆕首页搜索=设置旁放大镜→玻璃搜索弹层→媒体库优先（FNOSDirectClient.searchItems searchTerm+Recursive）→TMDB 兜底（FNOSTMDBClient.search /search/multi 过滤 person）→点结果进对应详情页
- **v195**：搜索框 textFieldStyle(.plain) 去系统底 + 首页设置/搜索按钮对调
- **v196**：KS 滑块 shouldBegin 让位=**死代码**（漏挂 recognizer.delegate）
- **v197**：KS 滑块真根因修复（补 recognizer.delegate=FNOSPanBridge.shared，**用户确认已解决 ✓ 结案勿再改**）+ 搜索框 focusEffectDisabled + 屏保所有权归容器
- **v198**：搜索框灰块根除=胶囊填充 Color.clear 只留纯描边（自绘半透明白填充叠玻璃面板=实心灰，且随焦点移动）
- **v199/v200**：搜索框改官方 searchable（🚨tvOS 无 searchFocused API=iOS 专属，编译已踩坑；聚焦由系统管理）；防抖实时搜索 450ms
- **v201**：MPV 屏保真根因=**SwiftUI Group 把修饰符分发给每个子视图**——容器 onAppear(true)/onDisappear(false) 在 KS→MPV 切换时 KS 的 false 后触发→屏保；修复=容器 Group→ZStack + MPV ticker 每 250ms 重申 true（双保险）
- **v202**：MPV 弹幕白变灰=MPVUI HDRPolicy 默认 .automatic 杜比视界以 HDR EDR 直出→电视切 HDR 模式→系统把 App 的 SDR 浮层整体压暗；修复=hdrPolicy:.disabled（对照 MPVUI v0.7.0 锁定版源码确认）
- **v203**：诊断版（弹幕数据层+渲染管线两路日志落 9999）
- **v204**：displayMatching:.disabled（日志实锤第二颗雷：displayMatching .automatic 仍按杜比视界片源把电视切进 HDR 模式）
- **v205**：sdrOutput:.compatibility8Bit（MPV 输出层从 linear float16 P3 降级为 8-bit sRGB，与 KS 视频层同类）→ **用户确认弹幕颜色已修复 ✓ MPV 色彩战役闭环**

### 🚨 新铁律与踩坑（v188-v205，违反过全都付出了代价）
1. **MPV 输出配置三件套已定案勿再改**：`hdrPolicy:.disabled` + `displayMatching:.disabled` + `sdrOutput:.compatibility8Bit`（SDR 全链路：层=8-bit sRGB，bt.2390 色调映射生效，弹幕/字幕/控制条纯白与 KS 一致）。**代价=无 HDR 直出/峰值亮度降至 SDR/宽色域收窄 bt.709（用户知情接受）。** 若未来要 HDR 直出+白弹幕=需把弹幕渲染进 EDR 空间，tvOS SwiftUI 对 Text 无官方 EDR 路径，工程量大不可控。
2. **SwiftUI Group 把修饰符分发给每个子视图**：容器生命周期的 onAppear/onDisappear 挂在 Group 上，会在 if/else 分支切换（KS↔MPV）时各自触发且顺序不定（KS 的 false 后触发=屏保）。需要"整容器只触发一次"的修饰符一律挂 ZStack/VStack 等真实容器。
3. **手势 recognizer 不挂 delegate=死代码**：FNOSPanBridge.shouldBegin（v196）因漏挂 recognizer.delegate 从未生效，v197 补上才修复。新增 recognizer 必须同时挂 delegate。
4. **tvOS 无 searchFocused API**（iOS 专属，编译报 unavailable）；官方 searchable 的聚焦由系统管理，弹层打开后焦点若未自动落框属系统行为。
5. **官方 searchable 是搜索框的定稿方案**：自绘 TextField（.plain+focusEffectDisabled+透明胶囊+描边）穷尽组合仍有系统聚焦灰盖；`.searchable` 输入框/键盘/聚焦外观全部系统绘制，勿再回退自绘。
6. **弹幕数据层已验证正确**（诊断日志：77119 条 98% 纯白、100% 不透明、解析 0xFFFFFF→1.0/1.0/1.0）——弹幕颜色问题先查渲染/显示合成层，勿再查数据层。
7. **诊断日志先行**：MPV 弹幕灰三轮盲猜失败，v203 两路日志（弹幕数据层+渲染管线）一次实锤（根因=displayMatching 切电视进 HDR 模式）。播放器渲染/颜色问题先加 FNOSDiagLog 诊断再改。
8. **hosts 裸连通道**（梯子坏期间）：hosts 固定真实 IP——github.com→140.82.113.3/116.3（轮换重试）、api.github.com→20.205.243.168、objects.githubusercontent.com→20.200.245.247；备份 hosts.bak_fnos；代理恢复后删 '# fnos github bypass' 段；GFW 偶发重置=轮换 IP 重试即通。
9. **用户确认已解决、禁止回滚**：KS 滑块触摸滑动（v197）、MPV 屏保（v201 ZStack+ticker）、弹幕颜色（v205 SDR 三件套）、搜索框（v200 官方 searchable）、弹幕设置滑块手感（v193 直连绑定）。
10. **FNOSDiag 与 FNOSDiagLog 是两条通道**：FNOSDiag=内存环形缓冲+print（设置面板 FNOSDiagView 用）；FNOSDiagLog.send=POST 9999 落盘。播放侧诊断必须走 FNOSDiagLog（v188 已把 FNOSDiag.add 并入）。

### 待解决问题清单（更新于 v207）
1. **片头片尾 v207 真机验证**（面板已重做：实时位置 + 取当前位置 + ±1s 微调；清单见 §2.5.1）：播剧集到片头结束处 → 开面板确认「当前位置」在走 → 确认键取当前位置做片头 → 回退重播本集验证片头自动跳 → 同法设片尾（确认片尾开始点显示正确）→ 退出重进验证服务端值回读 → Web 端改值 tvOS 生效 → 连播回归。电影场景：面板应显示「仅本次播放生效」（服务端实测无存储位）。
2. 续播卡第 3+ 张上键无落点（方案 A 落设置按钮失败、binding 方案真机不完美——需新思路）
3. TMDB infoSection 死代码清理（未被 body 引用）
4. 直播/MV 行恢复（数据通道已验证，播放层搁置）
5. 「已在库中」精细化（MP 转移历史端点未探）
6. 番剧名匹配边界（MP 转存后以 TMDB 名为准）
7. MPV 选集条缩略图（原生 EpisodeRef 无缩略图=渐变占位，可从 compat 层补拉）
8. 弹幕极轻微停顿（v174 后残留，需录屏定位）

### 未来优化方向（按价值排序，未排期）
1. **搜索增强**：搜索历史（UserDefaults 持久化最近 N 条）/拼音首字母匹配/TMDB 海报预载（点进详情页零等待）
2. **MPV 选集条补缩略图**：compat 层 Shows/{id}/Episodes 有 still 数据，按 guid 映射回填 4 大卡
3. **弹幕 EDR 渲染**（远期）：若恢复 HDR 直出，弹幕需渲染进扩展线性空间（tvOS SwiftUI Text 无官方路径，需 CoreText/Metal 自绘，工程量大）
4. **播放器设置持久化面板**：当前弹幕设置即时生效但无全局预览，可加最小化预览条
5. **续播体验**：第 3+ 张续播卡上键落点；KS/MPV 续播选择窗样式统一复查
6. **片头片尾面板增强**（远期，用户有需求再做）：长按进度条快捷跳过；「本集不再跳」临时禁用
