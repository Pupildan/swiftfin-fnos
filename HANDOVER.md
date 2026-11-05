# HANDOVER.md — Swiftfin→飞牛影视(fnOS) tvOS 客户端 交接文档

> 仓库：`Pupildan/swiftfin-fnos`（GitHub 私有仓，CI 构建 unsigned ipa）
> 本地工作区：`C:\Users\Admin\WorkBuddy\fndanmu-tvos\build-package\swiftfin-fnos`
> 当前版本：**v131**（commit 2580b49），版本标识在 `Shared/Services/FNOSAdapterBuild.swift`
> 交付物命名规则：`output/Swiftfin-FNOS-tvos-unsigned-vXX.ipa`（32MB 左右）

---

## ⚠️🚨 弹幕 sync anchor 逻辑——严禁改动（v130 严重回归教训）

**`FNOSDanmuView.swift` 的 `FNOSDanmuEngine.sync(mediaTime:)` 中 `anchorMediaTime = mediaTime`（精确等于播放器时间）是经过真机验证的唯一正确做法，绝对不要改。**

v130 我为了修「KS 轻微左右抖 + mpv 原地抖后重载」，把小漂移改成渐进校正（`anchorMediaTime = extrapolated + drift*0.15`，每次只纠 15%）。**结果灾难性变差**：KSPlayer 从轻微抖变**严重抖动+崩溃**，mpv **完全无法显示弹幕**。用户真机暴怒。

**根因**：渐进校正让 anchor 不再精确等于播放器 mediaTime，外推基点漂移→弹幕位置计算错乱→KS 抖动加剧甚至崩溃；mpv 侧 anchor 错乱导致弹幕完全不渲染。

**已在 v131（2580b49）回滚到原始 `sync()`**（硬重置 if drift>1.0 + `anchorMediaTime = mediaTime`）。**任何「渐进/平滑校正」都会破坏弹幕，严禁再动 sync 的 anchor 逻辑。**

---

## 📋 近期版本演进（v123-v131）

- **v123**：豆瓣详情页 frodo 私有 API（简介/类型/主演/导演）+ 入库按钮。**引入回归**：把详情页内容（简介等）错加到首页 Hero，破坏 Hero 焦点逻辑（右滑/右键焦点窜到继续播放）。
- **v124-v126**：首页 Hero 回滚 v122（删错加的内容区），只保留海报标题换行；新增「豆瓣热门」行（60 条=电影/电视剧/综艺 各 20，网页 JSON 端点）。
- **v127**：入库按钮背景改苹果液态玻璃 `.glassEffect`（替换 inLibrary 绿底）。
- **v128**：修豆瓣海报不显示——豆瓣 CDN 防盗链（无 Referer→418 空图），海报加载加 `Referer: movie.douban.com`。
- **v129**：豆瓣详情页接 frodo 私有 API（`/movie/{id}` id 在路径，`_api_key=0dad551...`，简介字段=intro，Swift 用 `Insecure.SHA1`）。**但 frodo 签名初版有编译错误（SHA1/upper/CharacterSet），两次修复**。
- **v130**：弹幕「渐进校正」——**严重回归**（见上方警告），已回滚。
- **v131**：修首页 Hero 焦点跳页（三按钮补全右左导航）+ 豆瓣详情页照搬 TMDB 布局（hero+简介+主演头像+评论+按标题入库）+ 豆瓣海报高清 m_ratio + 弹幕回滚。

---

## 一、项目架构与核心文件树

### 1.1 有用的 Swift 文件（全部，共 11 个）

```
Swiftfin tvOS/App/SwiftfinApp.swift      # @main 入口，极简：直接 render FNOSRootView()，绕开 Swiftfin 原登录栈
Shared/Services/FNOSAdapterBuild.swift   # 版本号 version/changes（每次交付必须递增，用户在设置面板核对版本）
Shared/Services/FNOSAuthStore.swift      # 凭据存储(UserDefaults key="fnos.credentials.v1") + 登录请求(POST /Users/AuthenticateByName)
Shared/Services/FNOSDirectClient.swift   # 网络层核心：纯 URLSession 直连客户端 + 全部 JSON 模型(FNOSItem等, PascalCase)
Shared/Views/FNOSRootView.swift          # 根路由：已登录→FNOSMainView，未登录→FNOSLoginView
Shared/Views/FNOSLoginView.swift         # 登录界面（服务器地址/用户名/密码）
Shared/Views/FNOSMainView.swift          # 首页：Hero Banner + 媒体库海报墙 + 左上角设置按钮(刷新/退出/版本面板)
Shared/Views/FNOSHeroView.swift          # ATV+ 风格全屏 Hero：自绘轮播+5秒预告(AV/KS双通道)+按钮焦点翻页
Shared/Views/FNOSPlayerView.swift        # 播放器：KSPlayer 混合引擎 + 自绘控制条 + 弹幕接线（含 FNOSPlayerContainerView）
Shared/Views/FNOSDanmuView.swift         # 弹幕：FNOSDanmuEngine(匹配/拉取/时间轴) + 渲染视图(UIImage预渲染缓存)
Shared/Views/FNOSAsyncImage.swift        # 带鉴权头的异步图片组件 + 内存缓存(FNOSImageCache, NSCache 400张)
```

**其余原 Swiftfin 源码已全部删除**（732 → 10 文件，pbxproj 用同步文件夹，删盘即生效）。工程里残留的 `Swiftfin/`、`SwiftfinMacros/`、`Translations/`、`Scripts/`、`fastlane/` 等目录对 tvOS target **不参与编译**（v12 已把 Generate Strings 脚本阶段连根拔掉）。

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

### 3.3 首页（FNOSMainView）

- 结构：GeometryReader 全屏 → ZStack{ 黑底 / ScrollView{ Hero(全屏高) + VStack 媒体库行 } / 左上角设置按钮 }
- 媒体库墙：**外层必须用非懒 VStack**（LazyVStack 屏外行不实例化，焦点引擎无落点——v30 下键失效的根因）；行内 LazyHStack 卡片 `.buttonStyle(.card)` + 每张卡 `.focused($shelfCardFocused, equals: item.Id)`
- Hero 抽选：只抓 `type=="Movie"`，每日一次存 UserDefaults(`fnos.hero.date`/`fnos.hero.ids`)；设置里"刷新媒体库"= 清 heroDate 强制重抽 + 清 FNOSImageCache + URLCache
- 设置面板 `FNOSHomeSettingsView`（sheet）：刷新媒体库 / 退出登录 / 版本信息

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
