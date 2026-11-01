import Foundation
#if canImport(JellyfinAPI)
import JellyfinAPI

/// 适配器：把飞牛的响应模型映射为 Swiftfin 现有的 `BaseItemDto`。
///
/// 目标：UI 层（Views / ViewModels / Coordinators）继续消费 `BaseItemDto`，
/// 无需感知数据源已经从 Jellyfin 换成了飞牛。
///
/// ⚠️ 与 Jellyfin 语义的两个易错点：
/// - 季号 → `parentIndexNumber`，集号 → `indexNumber`（Jellyfin 约定）
/// - 秒 → `runTimeTicks` 需要 ×10_000_000（100ns tick）
public enum FNOSItemMapper {

    // MARK: - FNOSPlayListItem → BaseItemDto

    public static func baseItemDto(from item: FNOSPlayListItem) -> BaseItemDto {
        let ticks: Int? = item.effectiveDurationSeconds.map { $0 * 10_000_000 }
        let positionTicks = (item.ts ?? 0) * 10_000_000

        var playedPercentage: Double?
        if let duration = item.effectiveDurationSeconds, duration > 0,
           let ts = item.ts, ts > 0 {
            playedPercentage = min(Double(ts) / Double(duration) * 100, 100)
        }

        var dto = BaseItemDto(
            childCount: item.type == "TV" ? item.numberOfEpisodes : nil,
            communityRating: item.voteAverage.flatMap(Float.init),
            id: item.guid,
            indexNumber: episodeIndex(of: item),
            name: item.displayName,
            overview: item.overview,
            parentIndexNumber: seasonIndex(of: item),
            premiereDate: FNOSDate.parse(item.airDate ?? item.releaseDate),
            providerIDs: item.imdbId.map { ["Imdb": $0] },
            runTimeTicks: ticks,
            seriesID: item.parentGuid,
            seriesName: item.tvTitle ?? item.parentTitle,
            type: BaseItemKind(fnosType: item.type),
            userData: UserItemDataDto(
                isFavorite: item.isFavorite.map { $0 == 1 },
                isPlayed: item.watched.map { $0 == 1 },
                itemID: item.guid,
                key: item.guid,
                playbackPositionTicks: item.ts.map { _ in positionTicks },
                playedPercentage: playedPercentage
            )
        )

        // 海报相对路径暂存到 imageTags["Primary"]，
        // 展示时通过 BaseItemDto.fnosPosterURL(client:) 还原为飞牛图片接口 URL
        if let poster = item.poster, !poster.isEmpty {
            dto.imageTags = (dto.imageTags ?? [:]).merging(["Primary": poster]) { _, new in new }
        }
        return dto
    }

    /// Jellyfin 语义：集号 → indexNumber（仅 Episode）
    private static func episodeIndex(of item: FNOSPlayListItem) -> Int? {
        guard item.type == "Episode" else { return nil }
        return item.episodeNumber
    }

    /// Jellyfin 语义：季号 → parentIndexNumber（仅 Episode）
    private static func seasonIndex(of item: FNOSPlayListItem) -> Int? {
        guard item.type == "Episode" else { return nil }
        return item.seasonNumber
    }

    // MARK: - FNOSMediaDb → BaseItemDto（媒体库 → 首页用户视图）

    public static func baseItemDto(from db: FNOSMediaDb) -> BaseItemDto {
        var dto = BaseItemDto(
            collectionType: db.category == "TV" ? .tvshows : .movies,
            id: db.guid,
            name: db.title,
            type: .collectionFolder
        )
        if let poster = db.primaryPosterPath {
            dto.imageTags = ["Primary": poster]
        }
        return dto
    }

    // MARK: - 批量

    public static func baseItemDtos(from items: [FNOSPlayListItem]) -> [BaseItemDto] {
        items.map(baseItemDto(from:))
    }
}

// MARK: - 图片解析

public extension BaseItemDto {
    /// 飞牛的图片不走 Jellyfin 的 /Items/{id}/Images 规则，
    /// 而是统一走 /v/api/v1/sys/img + poster 相对路径。
    /// Swiftfin 原有的 `BaseItemDto+Images` 扩展需要按此调整（详见 README）。
    /// - Parameter client: 用于拼接 baseURL 的客户端
    func fnosPosterURL(client: FNOSAPIClient, width: Int = 400) -> URL? {
        guard let path = imageTags?["Primary"], !path.isEmpty else { return nil }
        return client.imageURL(fromPath: path, width: width)
    }

    /// 背景大图（列表项只有 poster，详情页可用 playInfo.item.backdrops）
    func fnosBackdropURL(client: FNOSAPIClient, backdropPath: String, width: Int = 1280) -> URL? {
        guard !backdropPath.isEmpty else { return nil }
        return client.imageURL(fromPath: backdropPath, width: width)
    }
}

// MARK: - 类型映射

public extension BaseItemKind {
    /// 飞牛 type 字符串 → Jellyfin BaseItemKind
    init?(fnosType: String?) {
        switch fnosType {
        case "Movie":               self = .movie
        case "Video":               self = .video
        case "Episode":             self = .episode
        case "Season":              self = .season
        case "TV", "Series":        self = .series
        case "Directory", "Folder": self = .folder
        case "LiveChannel":         self = .channel
        default:                    return nil
        }
    }
}
#endif

// MARK: - 显示名（不依赖 JellyfinAPI，可独立测试）

extension FNOSPlayListItem {
    /// 剧集显示名："剧名 第N集"，其余用自身标题
    var displayName: String {
        if let tvTitle, !tvTitle.isEmpty, type == "Episode" {
            if let ep = episodeNumber, ep > 0 {
                return "\(tvTitle) 第\(ep)集"
            }
            return tvTitle
        }
        return title ?? ""
    }
}

// MARK: - 日期解析

enum FNOSDate {
    private static let dateOnly: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(secondsFromGMT: 0)
        return f
    }()

    private static let iso8601: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    static func parse(_ string: String?) -> Date? {
        guard let string, !string.isEmpty else { return nil }
        if let date = iso8601.date(from: string) { return date }
        return dateOnly.date(from: String(string.prefix(10)))
    }
}
