//
// Swiftfin is subject to the terms of the Mozilla Public
// License, v2.0. If a copy of the MPL was not distributed with this
// file, can be obtained one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2026 Jellyfin & Jellyfin Contributors
//

import SwiftUI
import UIKit

// MARK: - URL 构造扩展（只读 FNOSDirectClient 公开属性，不修改网络层文件）

extension FNOSDirectClient {

    /// 鉴权头全集：飞牛要求老式 X-Emby-Authorization；图片/播放直链双头都带上
    var mediaHeaders: [String: String] {
        [
            "X-Emby-Authorization": authorizationHeader,
            "Authorization": authorizationHeader,
            "X-Emby-Token": token,
        ]
    }

    /// 海报 URL —— 实测 fnOS 必须带 tag 参数，否则 404
    func posterURL(itemID: String, tag: String?, maxWidth: Int = 400) -> URL? {
        var query = [
            "maxWidth": String(maxWidth),
            "quality": "85",
        ]
        if let tag, !tag.isEmpty {
            query["tag"] = tag
        }
        do {
            return try url(path: "Items/\(itemID)/Images/Primary", query: query)
        } catch {
            print("FNOS❗️海报 URL 构造失败 \(itemID): \(error.localizedDescription)")
            return nil
        }
    }

    /// 剧集卡片横图：优先 Thumb（真正的 16:9 剧照）→ Primary → Backdrop
    func episodeStillURL(item: FNOSItem, maxWidth: Int = 640) -> URL? {
        let tags = item.ImageTags ?? [:]
        let imageType: String
        var tag: String?
        if let thumb = tags["Thumb"], !thumb.isEmpty {
            imageType = "Thumb"
            tag = thumb
        } else if let primary = tags["Primary"], !primary.isEmpty {
            imageType = "Primary"
            tag = primary
        } else if let backdrop = item.BackdropImageTags?.first, !backdrop.isEmpty {
            imageType = "Backdrop"
            tag = backdrop
        } else {
            imageType = "Primary"
        }
        var query = ["maxWidth": String(maxWidth), "quality": "85"]
        if let tag, !tag.isEmpty {
            query["tag"] = tag
        }
        return try? url(path: "Items/\(item.Id)/Images/\(imageType)", query: query)
    }

    /// 继续播放卡横图：剧集优先 Thumb 剧照；电影优先 Backdrop；都没有退 Primary
    func resumeStillURL(item: FNOSItem, maxWidth: Int = 640) -> URL? {
        if item.type == "Episode", let still = episodeStillURL(item: item, maxWidth: maxWidth) {
            return still
        }
        if let tag = item.BackdropImageTags?.first, !tag.isEmpty,
           let url = try? url(
               path: "Items/\(item.Id)/Images/Backdrop",
               query: ["maxWidth": String(maxWidth), "quality": "85", "tag": tag]
           ) {
            return url
        }
        return episodeStillURL(item: item, maxWidth: maxWidth)
    }

    /// 播放直链 —— 实测 static=true 返回原始媒体流
    func streamURL(itemID: String) -> URL? {
        do {
            return try url(
                path: "Videos/\(itemID)/stream",
                query: [
                    "static": "true",
                    "MediaSourceId": "",
                    "api_key": token,
                ]
            )
        } catch {
            print("FNOS❗️播放 URL 构造失败 \(itemID): \(error.localizedDescription)")
            return nil
        }
    }
}

// MARK: - 内存缓存（快速滑动不重复请求）

@MainActor
final class FNOSImageCache {
    static let shared = FNOSImageCache()

    /// 通用缓存：1920 横图 / 剧照 / 头像等大图。v84 加成本核算（压缩字节）+
    /// totalCostLimit——详情页每 2s 轮播一张 ~8MB 解码横图，此前 countLimit=400
    /// 的混合缓存反复进出详情后把海报墙的图全部挤出 → 返回时整墙「黑色转圈」重载。
    let memory: NSCache<NSString, UIImage>

    /// v84 海报专用缓存：海报墙瓦片 / 行副本 / 选集卡（~0.1-1MB/张，按张数管理）。
    /// 与大图缓存完全隔离——详情页横图轮播的内存churn永远不会挤掉海报，
    /// 且这是反复进出详情不转圈的硬保证（NSCache 的内存警告驱逐只波及大图侧）。
    let posters: NSCache<NSString, UIImage>

    private init() {
        let cache = NSCache<NSString, UIImage>()
        cache.countLimit = 400
        cache.totalCostLimit = 80 * 1024 * 1024   // 80MB（按压缩字节计成本）
        memory = cache

        let posterCache = NSCache<NSString, UIImage>()
        posterCache.countLimit = 300
        posters = posterCache
    }

    func cache(forPoster: Bool) -> NSCache<NSString, UIImage> {
        forPoster ? posters : memory
    }
}

// MARK: - 带鉴权的异步图片（替代会 401 的原生 AsyncImage）

struct FNOSAsyncImage: View {

    let url: URL?
    let headers: [String: String]
    var contentMode: ContentMode = .fill
    /// v84：海报类小图走独立 posters 缓存（海报墙/行副本/选集卡传 true），
    /// 与 1920 横图通用缓存隔离，杜绝互相挤兑。
    var usePosterCache: Bool = false

    private enum Phase {
        case loading, loaded, failed
    }

    @State private var image: UIImage?
    @State private var phase: Phase = .loading

    var body: some View {
        // v84：首帧同步查缓存。视图被重建时（从详情返回海报墙、行副本插入等），
        // .task 是异步的——此前哪怕缓存命中也要先渲染一帧 loading（黑底转圈）。
        // body 内同步查一次：命中则第一帧直接出图，转圈彻底消失。
        let syncCached: UIImage? = (phase != .loaded)
            ? url.flatMap {
                FNOSImageCache.shared.cache(forPoster: usePosterCache)
                    .object(forKey: $0.absoluteString as NSString)
            }
            : nil
        let resolvedImage = image ?? syncCached
        let resolvedLoaded = phase == .loaded || (syncCached != nil && phase == .loading)
        return ZStack {
            if resolvedLoaded, let resolvedImage {
                Image(uiImage: resolvedImage)
                    .resizable()
                    .aspectRatio(contentMode: contentMode)
                    .transition(.opacity)
            } else if phase == .failed {
                Rectangle()
                    .fill(Color.white.opacity(0.06))
                Image(systemName: "film")
                    .font(.title2)
                    .foregroundColor(.white.opacity(0.35))
            } else {
                Rectangle()
                    .fill(Color.white.opacity(0.06))
                ProgressView()
            }
        }
        .animation(.easeOut(duration: 0.25), value: phase)
        .task(id: url) {
            // 关键：url 变化（翻页 / 刷新媒体库 / 视图被复用）先清空旧图，
            // 否则新条目会短暂显示上一部电影的海报 = 图文错位。
            image = nil
            phase = .loading
            await load()
        }
    }

    private func load() async {
        guard let url else {
            phase = .failed
            return
        }

        // 注意：SwiftUI View 是值类型，异步返回后 self.url 仍是调用时的快照，
        // 判断「URL 是否已变」只能靠 .task(id: url) 的取消机制（Task.isCancelled）。
        let key = url.absoluteString as NSString
        let cache = FNOSImageCache.shared.cache(forPoster: usePosterCache)
        if let cached = cache.object(forKey: key) {
            guard !Task.isCancelled else { return }
            image = cached
            phase = .loaded
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 20
        for (field, value) in headers {
            request.setValue(value, forHTTPHeaderField: field)
        }

        do {
            let (data, response) = try await URLSession.shared.data(for: request)

            guard let http = response as? HTTPURLResponse else {
                throw FNOSDirectError("海报非 HTTP 响应: \(String(describing: response))")
            }
            guard (200..<300).contains(http.statusCode) else {
                throw FNOSDirectError("海报 HTTP \(http.statusCode): \(url.absoluteString)")
            }
            // 后台解码：UIImage(data:) 的解码发生在首次绘制时（主线程），
            // 大图会让滚动/翻页掉帧。这里用 ImageIO 在后台线程完成解码。
            let imageData = data
            let decodedImage = await Task.detached(priority: .userInitiated) { () -> UIImage? in
                guard let sourceData = imageData as NSData?,
                      let source = CGImageSourceCreateWithData(sourceData, nil),
                      let cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil)
                else {
                    return UIImage(data: imageData)
                }
                return UIImage(cgImage: cgImage)
            }.value

            guard let decoded = decodedImage else {
                throw FNOSDirectError("海报解码失败: \(url.absoluteString)")
            }

            // v84：cost = 压缩字节数。通用缓存按成本驱逐（1920 横图远重于海报），
            // 防止详情页轮播大图把缓存挤爆；海报缓存按张数管理（cost 被忽略）
            cache.setObject(decoded, forKey: key, cost: data.count)
            // 过期结果丢弃：url 已变（.task 被取消）时不要覆盖当前视图
            guard !Task.isCancelled else { return }
            image = decoded
            phase = .loaded
        } catch {
            guard !Task.isCancelled else { return }
            // 图片失败不阻塞界面：显示占位符，报错走 print 可查
            print("FNOS❗️海报加载失败: \(error.localizedDescription)")
            phase = .failed
        }
    }
}
