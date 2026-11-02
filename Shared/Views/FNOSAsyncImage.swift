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

    let memory: NSCache<NSString, UIImage>

    private init() {
        let cache = NSCache<NSString, UIImage>()
        cache.countLimit = 400
        memory = cache
    }
}

// MARK: - 带鉴权的异步图片（替代会 401 的原生 AsyncImage）

struct FNOSAsyncImage: View {

    let url: URL?
    let headers: [String: String]
    var contentMode: ContentMode = .fill

    private enum Phase {
        case loading, loaded, failed
    }

    @State private var image: UIImage?
    @State private var phase: Phase = .loading

    var body: some View {
        ZStack {
            switch phase {
            case .loading:
                Rectangle()
                    .fill(Color.white.opacity(0.06))
                ProgressView()
            case .failed:
                Rectangle()
                    .fill(Color.white.opacity(0.06))
                Image(systemName: "film")
                    .font(.title2)
                    .foregroundColor(.white.opacity(0.35))
            case .loaded:
                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .aspectRatio(contentMode: contentMode)
                        .transition(.opacity)
                }
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
        if let cached = FNOSImageCache.shared.memory.object(forKey: key) {
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
            guard let decoded = UIImage(data: data) else {
                throw FNOSDirectError("海报解码失败: \(url.absoluteString)")
            }

            FNOSImageCache.shared.memory.setObject(decoded, forKey: key)
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
