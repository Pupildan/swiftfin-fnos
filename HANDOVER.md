# HANDOVER.md — Swiftfin→飞牛影视(fnOS) tvOS 客户端 交接文档

> 仓库：`Pupildan/swiftfin-fnos`（GitHub 私有仓，CI 构建 unsigned ipa）
> 本地工作区：`C:\Users\Admin\WorkBuddy\fndanmu-tvos\build-package\swiftfin-fnos`
> 当前版本：**v178**（评论弹窗滚动/透明度 + 已入库下键进内容区回滚；commit 9c08b1b），版本标识在 `Shared/Services/FNOSAdapterBuild.swift`
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
Shared/Views/FNOSPlayerView.swift        # 播放器：KSPlayer 混合引擎 + 自绘控制条 + 弹幕接线（含 FNOSPlayerContainerView）
Shared/Views/FNOSMPVPlayerView.swift     # mpv 引擎（MPVUI）：DoVi P5/P7 接管 + tone-mapping
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
