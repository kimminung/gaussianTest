import Foundation

/// 프레임 단위로 스플랫을 공급하는 소스. 정지 장면은 frameCount == 1.
nonisolated protocol SplatSource: Sendable {
    var frameCount: Int { get }
    var framesPerSecond: Double { get }
    /// 프레임을 디코드해 돌려준다. 호출자(메인 액터) 밖에서 돌도록 actor 로 구현한다.
    func frame(at index: Int) async throws -> SplatCloud
}

// MARK: - PLY 한 장

/// 3DGS PLY 파일 하나. 첫 요청 때 파싱하고 캐시한다.
actor PLYFileSource: SplatSource {
    nonisolated let frameCount = 1
    nonisolated let framesPerSecond: Double = 1
    let url: URL
    private var cached: SplatCloud?

    init(url: URL) {
        self.url = url
    }

    func frame(at index: Int) async throws -> SplatCloud {
        if let cached { return cached }
        let cloud = try Self.load(url)
        cached = cloud
        return cloud
    }

    static func load(_ url: URL) throws -> SplatCloud {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        return try PLYSplatParser.parse(data)
    }
}

// MARK: - PLY 프레임 폴더

/// 폴더 안의 `*.ply` 를 이름순(숫자 인식)으로 정렬해 4D 시퀀스로 다룬다.
/// 선택 파일 `sequence.json`: `{ "fps": 24, "flipY": true }`
actor PLYSequenceSource: SplatSource {
    struct Manifest: Decodable {
        var fps: Double?
        var flipY: Bool?
    }

    enum SequenceError: LocalizedError {
        case empty
        var errorDescription: String? { "폴더에 .ply 파일이 없습니다." }
    }

    nonisolated let frameCount: Int
    nonisolated let framesPerSecond: Double
    nonisolated let defaultFlipY: Bool
    nonisolated let folderURL: URL
    private let frameURLs: [URL]

    private var cache: [Int: SplatCloud] = [:]
    private var order: [Int] = []
    private var inflight: [Int: Task<SplatCloud, Error>] = [:]
    private let cacheLimit = 12
    private let prefetchDepth = 2

    init(folderURL: URL, fallbackFPS: Double = 30) throws {
        self.folderURL = folderURL
        let scoped = folderURL.startAccessingSecurityScopedResource()
        defer { if scoped { folderURL.stopAccessingSecurityScopedResource() } }

        let items = try FileManager.default.contentsOfDirectory(
            at: folderURL,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )
        let plys = items
            .filter { $0.pathExtension.lowercased() == "ply" }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
        guard !plys.isEmpty else { throw SequenceError.empty }
        frameURLs = plys
        frameCount = plys.count

        var fps = fallbackFPS
        var flip = true
        let manifestURL = folderURL.appendingPathComponent("sequence.json")
        if let data = try? Data(contentsOf: manifestURL),
           let manifest = try? JSONDecoder().decode(Manifest.self, from: data) {
            if let f = manifest.fps, f > 0 { fps = f }
            if let fl = manifest.flipY { flip = fl }
        }
        framesPerSecond = fps
        defaultFlipY = flip
    }

    func frame(at index: Int) async throws -> SplatCloud {
        let i = ((index % frameCount) + frameCount) % frameCount
        let cloud = try await decode(i)
        for ahead in 1...prefetchDepth {
            schedule((i + ahead) % frameCount)
        }
        return cloud
    }

    private func schedule(_ i: Int) {
        guard cache[i] == nil, inflight[i] == nil else { return }
        let url = frameURLs[i]
        let folder = folderURL
        let task = Task<SplatCloud, Error>.detached(priority: .userInitiated) {
            let scoped = folder.startAccessingSecurityScopedResource()
            defer { if scoped { folder.stopAccessingSecurityScopedResource() } }
            let data = try Data(contentsOf: url, options: .mappedIfSafe)
            return try PLYSplatParser.parse(data)
        }
        inflight[i] = task
    }

    private func decode(_ i: Int) async throws -> SplatCloud {
        if let hit = cache[i] { return hit }
        schedule(i)
        guard let task = inflight[i] else { throw SequenceError.empty }
        let cloud = try await task.value
        inflight[i] = nil
        store(cloud, at: i)
        return cloud
    }

    private func store(_ cloud: SplatCloud, at i: Int) {
        cache[i] = cloud
        order.removeAll { $0 == i }
        order.append(i)
        while order.count > cacheLimit, let oldest = order.first {
            order.removeFirst()
            cache[oldest] = nil
        }
    }
}

// MARK: - 프로시저럴

/// 시간 함수로 프레임을 즉석 생성하는 소스(번들 샘플용).
actor ProceduralSplatSource: SplatSource {
    nonisolated let frameCount: Int
    nonisolated let framesPerSecond: Double
    private let generator: @Sendable (Double) -> SplatCloud

    init(frameCount: Int, framesPerSecond: Double, generator: @escaping @Sendable (Double) -> SplatCloud) {
        self.frameCount = frameCount
        self.framesPerSecond = framesPerSecond
        self.generator = generator
    }

    func frame(at index: Int) async throws -> SplatCloud {
        let i = ((index % frameCount) + frameCount) % frameCount
        return generator(Double(i) / framesPerSecond)
    }
}
