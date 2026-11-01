import Foundation

// MARK: - 响应信封

/// 飞牛服务端统一响应信封：{ "code": 0, "msg": "...", "data": ... }
/// code == 0 成功；code == -2 表示 token 失效，需要重新登录。
public struct FNOSResponse<T: Decodable>: Decodable {
    public let code: Int
    public let msg: String?
    public let data: T?
}

/// data 可能为 null 的接口使用此占位类型。
public struct FNOSEmpty: Decodable {
    public init(from decoder: Decoder) throws {
        // data 为 null 时解码失败没关系，仅吞掉即可
        _ = try? decoder.singleValueContainer().decode(Bool.self)
    }
}

// MARK: - 错误

public enum FNOSClientError: LocalizedError {
    /// code == -2：token 失效
    case authFailed
    /// 业务错误（code != 0）
    case server(code: Int, message: String?)
    /// 响应中缺少预期的 data
    case missingData

    public var errorDescription: String? {
        switch self {
        case .authFailed:
            return "飞牛影视登录已失效，请重新登录"
        case .server(_, let message):
            return message ?? "服务器返回未知错误"
        case .missingData:
            return "服务器响应缺少数据"
        }
    }
}

// MARK: - 登录

struct FNOSLoginRequest: Encodable {
    let appName: String
    let username: String
    let password: String
}

public struct FNOSLoginData: Decodable {
    public let token: String
}

public struct FNOSUserInfo: Decodable {
    public let name: String?
    public let alias: String?
    public let avatar: String?
}

// MARK: - 媒体库

/// GET /v/api/v1/mediadb/list 的条目
public struct FNOSMediaDb: Decodable {
    public let guid: String
    public let title: String
    public let poster: String?
    public let posters: [String]?
    /// "Mix"（电影库）/ "TV"（剧集库）等
    public let category: String?
    public let viewType: Int?
    public let posterType: Int?

    /// 第一张海报的相对路径（需拼接到图片接口）
    public var primaryPosterPath: String? {
        if let poster, !poster.isEmpty { return poster }
        return posters?.first { !$0.isEmpty }
    }
}

// MARK: - 条目列表

/// POST /v/api/v1/item/list 请求体
/// 对应 fnos_tv_danmu 的 ItemListRequest.java
public struct FNOSItemListRequest: Encodable {
    public struct Tags: Encodable {
        public let type: [String]
    }

    public let ancestorGuid: String?
    public let tags: Tags
    public let excludeGroupedVideo: Int?
    public let sortColumn: String
    public let sortType: String
    public let pageSize: Int
    public let page: Int?

    public init(ancestorGuid: String?, tags: [String], excludeGroupedVideo: Int?,
                sortColumn: String, sortType: String, pageSize: Int, page: Int? = nil) {
        self.ancestorGuid = ancestorGuid
        self.tags = Tags(type: tags)
        self.excludeGroupedVideo = excludeGroupedVideo
        self.sortColumn = sortColumn
        self.sortType = sortType
        self.pageSize = pageSize
        self.page = page
    }

    /// 浏览媒体库根目录（海报墙）
    public static func browseLibrary(_ guid: String) -> Self {
        .init(ancestorGuid: guid,
              tags: ["Movie", "TV", "Directory", "Video"],
              excludeGroupedVideo: 1,
              sortColumn: "create_time", sortType: "DESC", pageSize: 50)
    }

    /// 浏览剧集（按集数排序）
    public static func browseEpisodes(_ guid: String) -> Self {
        .init(ancestorGuid: guid,
              tags: ["Episode", "Movie", "Video"],
              excludeGroupedVideo: 1,
              sortColumn: "episode_number", sortType: "ASC", pageSize: 200)
    }

    /// 浏览文件夹（含子文件夹，按标题排序）
    public static func browseFolder(_ guid: String) -> Self {
        .init(ancestorGuid: guid,
              tags: ["Movie", "TV", "Directory", "Video", "Episode"],
              excludeGroupedVideo: 0,
              sortColumn: "sort_title", sortType: "ASC", pageSize: 200)
    }
}

/// POST /v/api/v1/item/list 响应
public struct FNOSItemListResponse: Decodable {
    public let total: Int
    public let list: [FNOSPlayListItem]
}

// MARK: - 万能条目（媒体库条目 / 剧 / 季 / 集 / 搜索结果共用）

/// 对应 fnos_tv_danmu 的 PlayListItem.java 与 fntv-electron 的 PlayListItem 接口。
/// 飞牛的列表类接口都用这套结构，靠 `type` 字段区分。
public struct FNOSPlayListItem: Decodable {
    public let guid: String
    public let title: String?
    /// Movie | TV | Directory | Video | Episode | Folder | LiveChannel ...
    public let type: String?
    public let poster: String?

    public let tvTitle: String?          // 剧名（Episode 用）
    public let parentTitle: String?
    public let parentGuid: String?
    public let ancestorName: String?     // 分类名，如 "日漫"
    public let ancestorCategory: String?

    public let overview: String?
    public let watched: Int?             // 1 已看
    public let ts: Int?                  // 播放进度（秒）
    public let duration: Int?            // 时长（秒）
    public let episodeNumber: Int?
    public let seasonNumber: Int?
    public let voteAverage: String?
    public let runtime: Int?             // 分钟
    public let isFavorite: Int?
    public let airDate: String?
    public let releaseDate: String?

    public let videoGuid: String?
    public let audioGuid: String?
    public let subtitleGuid: String?
    public let mediaGuid: String?

    public let doubanId: Int?            // ★ 弹幕匹配锚点
    public let imdbId: String?

    public let numberOfSeasons: Int?
    public let numberOfEpisodes: Int?

    public var isPlayable: Bool { ["Movie", "Video", "Episode"].contains(type ?? "") }
    public var isFolder: Bool { ["TV", "Directory", "Folder"].contains(type ?? "") }

    /// 有效时长（秒）：优先 duration，退回 runtime 分钟
    public var effectiveDurationSeconds: Int? {
        if let duration, duration > 0 { return duration }
        return runtime.map { $0 * 60 }
    }
}

// MARK: - 播放

/// POST /v/api/v1/play/info 请求体
struct FNOSPlayInfoRequest: Encodable {
    let itemGuid: String
}

/// POST /v/api/v1/play/info 响应（对应 PlayInfoResponse.java）
public struct FNOSPlayInfo: Decodable {
    public struct Item: Decodable {
        public let guid: String?
        public let title: String?
        public let tvTitle: String?
        public let parentTitle: String?
        public let overview: String?
        public let poster: String?
        public let posters: String?
        public let backdrops: String?
        public let stillPath: String?
        public let voteAverage: String?
        public let runtime: Int?
        public let duration: Int?
        public let episodeNumber: Int?
        public let seasonNumber: Int?
        public let airDate: String?
        public let releaseDate: String?
        public let watched: Int?
        public let isFavorite: Int?
    }

    public let guid: String
    public let type: String?
    public let parentGuid: String?
    public let mediaGuid: String?
    public let videoGuid: String?
    public let audioGuid: String?
    public let subtitleGuid: String?
    public let ts: Int?
    public let item: Item?
}

/// POST /v/api/v1/play/play 响应（相对路径形式的播放链接）
public struct FNOSPlayLink: Decodable {
    public let playLink: String?
    public let mediaGuid: String?
    public let subtitleLink: String?
    public let hlsTime: Int?
}

/// POST /v/api/v1/stream 响应（直链质量列表 / 字幕流）
public struct FNOSStreamResponse: Decodable {
    public struct DirectLinkQuality: Decodable {
        public let bitrate: Int?
        public let resolution: String?
        public let progressive: Bool?
        public let url: String?
        public let isM3u8: Bool?
        public let expiredAt: Int?
    }

    public struct SubtitleStream: Decodable {
        public let guid: String?
        public let title: String?
        public let format: String?
        public let isExternal: Bool?
    }

    public let directLinkQualities: [DirectLinkQuality]?
    public let subtitleStreams: [SubtitleStream]?
}

// MARK: - 播放状态上报

/// POST /v/api/v1/item/watched 请求体
struct FNOSWatchedRequest: Encodable {
    let itemGuid: String
}

/// POST /v/api/v1/play/record 请求体
public struct FNOSPlayStatus: Encodable {
    public let itemGuid: String
    public let ts: Int              // 当前播放位置（秒）
    public let duration: Int        // 总时长（秒）
    public let status: Int          // 1: 开始 2: 播放中 3: 暂停 4: 停止（以抓包为准，可按需调整）
    public let playUrl: String?

    public init(itemGuid: String, ts: Int, duration: Int, status: Int, playUrl: String? = nil) {
        self.itemGuid = itemGuid
        self.ts = ts
        self.duration = duration
        self.status = status
        self.playUrl = playUrl
    }
}
