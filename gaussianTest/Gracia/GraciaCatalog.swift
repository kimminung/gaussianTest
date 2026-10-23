import Foundation

/// Gracia 장면의 출처. 로컬 파일(.mint/.ply/.sog) 또는 HTTP(S) 스트림.
nonisolated enum GraciaSceneSource: Sendable, Equatable {
    case file(URL)
    case stream(url: String, token: String?)

    var displayName: String {
        switch self {
        case .file(let url): url.lastPathComponent
        case .stream(let url, _): URL(string: url)?.host() ?? url
        }
    }

    var isStream: Bool {
        if case .stream = self { return true }
        return false
    }
}

/// 라이브러리에 표시되는 Gracia 항목.
struct GraciaScene: Identifiable {
    enum Kind: String {
        case demo = "Gracia 데모"
        case file = "Gracia 파일"
    }

    let id = UUID()
    let title: String
    let subtitle: String
    let kind: Kind
    let source: GraciaSceneSource
}

/// Gracia 가 공개한 데모 4DGS 콘텐츠 목록(https://docs.gracia.ai/demo-data).
///
/// 이 파일에는 URL 만 있고 콘텐츠는 들어 있지 않다. 콘텐츠는 Gracia 의 CONTENT-LICENSE 를 따르며
/// 시연·평가 용도로만 재생할 수 있고, 재배포·변환·스플랫 추출·공개 배포가 금지된다.
nonisolated enum GraciaCatalog {
    /// Gracia 인프라 스트리밍 엔드포인트. 직접 링크(gstatic.gracia.ai)는 Cloudflare 챌린지로 403 을 돌려줘
    /// 앱에서 버퍼링만 계속되므로(2026-10-23 확인) 스트리밍 경로를 쓴다.
    static let streamingBase = "https://streaming.gracia.ai/api/v1/streaming/content/"

    /// Gracia 가 데모 데이터 페이지에 공개한 평가용 조회 토큰(X-VIEW-TOKEN). 만료되거나 바뀔 수 있다.
    static let demoViewToken = "eyJhbGciOiJIUzI1NiJ9.eyJpYXQiOjE3ODUxNjYyOTJ9.wGuwzPd-O6l-IuLFVgzWs0_kICg0CplKsbO1PT4cAHQ"

    static let licenseNotice =
        "Gracia 데모 콘텐츠 © Gracia Labs. 시연·평가 용도로만 재생할 수 있어요. 재배포·변환·공개 배포는 허용되지 않아요."

    static let licenseURL = URL(string: "https://github.com/gracia-labs/apple-sdk/blob/main/CONTENT-LICENSE")!

    struct DemoEntry {
        let title: String
        let subtitle: String
        let fileName: String
        let contentID: String
    }

    static let demos: [DemoEntry] = [
        DemoEntry(title: "Vivid & Translucent", subtitle: "패션 · 4DGS 볼류메트릭", fileName: "fashion_example_1724.mint", contentID: "5a2befb6-5072-4276-805a-89de87b4b373"),
        DemoEntry(title: "Liar Liar — McKenzi Brooke × Karl Kani", subtitle: "뮤직 퍼포먼스 · Fashionverse", fileName: "karl_kani_liar_liar.mint", contentID: "5c6e9301-ccc9-4f44-b409-869f591b4773"),
        DemoEntry(title: "Vivid & Translucent (스트리밍 최적화)", subtitle: "패션 · 스트리밍용 인코딩", fileName: "fashion_streaming.mint", contentID: "b8b6e566-20cf-4a3b-93a6-13252237d66e"),
        DemoEntry(title: "Doctor — Checking Joints", subtitle: "의료 교육 시연", fileName: "doctor_s2.mint", contentID: "01732b7e-063c-445d-b58f-98d2a25b909c"),
        DemoEntry(title: "Cycling — Awesome Velocity", subtitle: "스포츠", fileName: "cycling_example.mint", contentID: "cecb0585-6d2d-4010-b1bc-3627fdc4d2b7"),
        DemoEntry(title: "Amy May — Open", subtitle: "뮤직 퍼포먼스", fileName: "amy_may_streaming.mint", contentID: "2b55b6c2-9ed4-4633-b0f8-7ead5bfe5cfb"),
        DemoEntry(title: "Aim High", subtitle: "오디오 트랙 포함", fileName: "aim_high_streaming_with_audio.mint", contentID: "51260e4c-75fd-4b20-8b9f-a4d176e501a5"),
        DemoEntry(title: "Adventury XR — Learning The Ropes", subtitle: "체조", fileName: "adventury_gracia.mint", contentID: "2649fe09-a5db-4e94-a99e-e1b71646713e"),
        DemoEntry(title: "Learning The Ropes", subtitle: "체조", fileName: "gymnastic.mint", contentID: "5b1084ed-fb41-446e-8455-dc7579c18db0"),
        DemoEntry(title: "MMA — KO", subtitle: "격투 스포츠", fileName: "mma.mint", contentID: "4bb56594-499e-47bc-b88c-27167483f015"),
    ]

    @MainActor
    static func makeDemoScenes() -> [GraciaScene] {
        demos.map { entry in
            GraciaScene(
                title: entry.title,
                subtitle: entry.subtitle,
                kind: .demo,
                source: .stream(url: streamingBase + entry.contentID, token: demoViewToken)
            )
        }
    }

    static let supportedExtensions: Set<String> = ["mint", "ply", "sog"]

    /// 보안 범위 URL 을 앱 컨테이너로 복사한다. 렌더 스레드가 나중에 자기 컨텍스트에서 읽기 때문.
    static func copyIntoContainer(_ source: URL) throws -> URL {
        let scoped = source.startAccessingSecurityScopedResource()
        defer { if scoped { source.stopAccessingSecurityScopedResource() } }

        let dir = try FileManager.default
            .url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appendingPathComponent("GraciaScenes", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let destination = dir.appendingPathComponent(source.lastPathComponent)
        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }
        try FileManager.default.copyItem(at: source, to: destination)
        return destination
    }
}
