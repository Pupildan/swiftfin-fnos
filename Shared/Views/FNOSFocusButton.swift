//
// Swiftfin is subject to the terms of the Mozilla Public
// License, v2.0. If a copy of the MPL was not distributed with this
// file, can be obtained one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2026 Jellyfin & Jellyfin Contributors
//

import SwiftUI

/// 焦点按钮的统一外观（可独立定制，Hero 与详情页互不影响）
///
/// 视觉规则：
/// - 未聚焦：半透明液态玻璃（黑 35% + 白 25% 描边），白字
/// - 聚焦：纯白背景，黑字，1.06 放大
struct FNOSFocusButtonLabel: View {
    let isFocused: Bool
    let isPrimary: Bool
    let label: AnyView

    init<L: View>(isFocused: Bool, isPrimary: Bool, @ViewBuilder label: () -> L) {
        self.isFocused = isFocused
        self.isPrimary = isPrimary
        self.label = AnyView(label())
    }

    var body: some View {
        label
            .foregroundColor(isFocused ? .black : .white)
            .padding(.horizontal, isPrimary ? 34 : 0)
            .padding(.vertical, isPrimary ? 15 : 0)
            .frame(width: isPrimary ? nil : 54, height: isPrimary ? nil : 54)
            .background(
                Capsule()
                    .fill(isFocused ? Color.white : Color.black.opacity(0.35))
            )
            .scaleEffect(isFocused ? 1.06 : 1.0)
            .animation(.easeOut(duration: 0.16), value: isFocused)
    }
}

/// 主色提取：从海报图像采样若干像素，取最饱和、亮度适中的颜色作为页面主题色。
enum FNOSDominantColor {
    private static let cache = NSCache<NSString, UIColor>()

    static func color(for url: URL?, headers: [String: String]) async -> Color? {
        guard let url else { return nil }
        let key = url.absoluteString as NSString
        if let cached = cache.object(forKey: key) { return Color(uiColor: cached) }

        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        for (field, value) in headers { request.setValue(value, forHTTPHeaderField: field) }

        do {
            let (data, _) = try await URLSession.shared.data(for: request)
            let ui = await Task.detached(priority: .utility) { () -> UIColor? in
                guard let image = UIImage(data: data), let cg = image.cgImage else { return nil }
                return dominantColor(from: cg)
            }.value
            guard let ui else { return nil }
            cache.setObject(ui, forKey: key)
            return Color(uiColor: ui)
        } catch {
            return nil
        }
    }

    private static func dominantColor(from cgImage: CGImage) -> UIColor? {
        // 缩到 32x32 采色，开销极小
        let size = 32
        var pixels = [UInt8](repeating: 0, count: size * size * 4)
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(
                data: &pixels,
                width: size,
                height: size,
                bitsPerComponent: 8,
                bytesPerRow: size * 4,
                space: space,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              )
        else { return nil }

        ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: size, height: size))

        var bestScore: Double = -1
        var best: (r: Double, g: Double, b: Double) = (0.2, 0.25, 0.35)

        for index in stride(from: 0, to: pixels.count, by: 4) {
            let r = Double(pixels[index]) / 255
            let g = Double(pixels[index + 1]) / 255
            let b = Double(pixels[index + 2]) / 255
            let maxC = max(r, max(g, b))
            let minC = min(r, min(g, b))
            let saturation = maxC == 0 ? 0 : (maxC - minC) / maxC
            let brightness = (r + g + b) / 3

            // 太暗或太亮都不适合当背景色，偏向中等亮度 + 较高饱和度
            guard brightness > 0.15, brightness < 0.85 else { continue }
            let score = saturation * 1.6 + (1 - abs(brightness - 0.5))
            if score > bestScore {
                bestScore = score
                best = (r, g, b)
            }
        }
        return UIColor(red: best.r, green: best.g, blue: best.b, alpha: 1)
    }
}
