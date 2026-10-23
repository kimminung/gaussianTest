# 무대 (Mudae) — 태스크 문서

범례: ✅ 완료 · 🔧 진행 중 · ⬜ 대기 · 🧪 사용자/실기기 검증 필요 · ❌ 보류
갱신 2026-10-22

## M0 — 뼈대와 재생 경로

| ID | 태스크 | 파일 | 상태 |
|---|---|---|---|
| T-001 | 테크 PRD 작성 | Docs/TechPRD.md | ✅ |
| T-002 | 태스크 문서 작성 | Docs/Tasks.md | ✅ |
| T-003 | SDK 확인: 시뮬레이터에 GaussianSplatResource 없음, 기기/macOS 있음(@available 27) | — | ✅ |
| T-010 | SplatCloud 인터리브 레이아웃(16 float/스플랫) + 빌더 | MyApp/Splat/SplatCloud.swift | ✅ |
| T-011 | 3DGS PLY 파서(ascii / binary LE·BE, f_dc 또는 uchar rgb, 선택 속성 기본값) | MyApp/Splat/PLYSplatParser.swift | ✅ |
| T-012 | SplatSource 프로토콜 + PLY 파일 / 폴더 시퀀스(LRU·프리페치·sequence.json) 소스 | MyApp/Splat/SplatSource.swift | ✅ |
| T-013 | 프로시저럴 4D 샘플 3종(댄서·파동 바닥·별빛 나선, 8초 루프 30fps) | MyApp/Splat/SampleScenes.swift | ✅ |
| T-020 | SplatPlayer(시계 기준 프레임 계산, 배속, 반복, 탐색, revision) | MyApp/Splat/SplatPlayer.swift | ✅ |
| T-030 | SplatRenderer 네이티브 경로(LowLevelBuffer 재사용, 숨김 슬롯, 용량 초과 시 재생성) | MyApp/Render/SplatRenderer.swift | ✅ |
| T-031 | SplatRenderer 폴백 경로(색 버킷 64개 perFace 메시, 8k 샘플링) | MyApp/Render/SplatRenderer.swift | ✅ |
| T-032 | 상하 반전·바닥 맞춤·경계상자·충돌 박스 | MyApp/Render/SplatRenderer.swift | ✅ |
| T-040 | AppModel(라이브러리, 선택, 배치, 가져오기) | MyApp/App/AppModel.swift | ✅ |
| T-041 | 라이브러리 + 상세(미리보기·플레이어) UI | MyApp/Views/ContentView.swift, PlayerControlsView.swift | ✅ |
| T-042 | StageView(RealityView, 창 미리보기 맞춤 / 몰입 배치, 드래그·핀치) | MyApp/Views/StageView.swift | ✅ |
| T-043 | visionOS ImmersiveSpace(mixed/full 전환) | MyApp/MyApp.swift, Views/ImmersiveStageView.swift | ✅ |
| T-044 | fileImporter(.ply, 폴더) + 보안 범위 접근 | AppModel, ContentView | ✅ |
| T-050 | 빌드 3종(Any visionOS Device / Simulator / My Mac) | — | ✅ |
| T-051 | macOS 에서 네이티브 스플랫 재생 실행 확인 | — | ✅ 샘플 3종 모두 네이티브 렌더·재생 확인(디버그 빌드 디코드 39–68 ms → T-203) |
| T-054 | 번들 ID `com.coulson.Mudae`, 표시 이름 "무대", DEBUG 실행 인자 `-scene N` | — | ✅ |
| T-052 | 실기기(Vision Pro) 배치·드래그·핀치·몰입 전환 확인 | — | 🧪 |
| T-053 | 외부 3DGS PLY 1개 + PLY 시퀀스 폴더 1개로 실측(방향·바닥·fps) | — | 🧪 |

## M1 — 실기기 품질

| ID | 태스크 | 상태 |
|---|---|---|
| T-110 | Gracia 라이선스 분석(CONTENT-LICENSE 2(c)(d): 변환·추출 금지 → 어댑터 대신 SDK 통합으로 전환) | ✅ |
| T-111 | Gracia SDK SwiftPM 의존성(리비전 고정) + 플랫폼 `macosx xros` 축소 + network.client | ✅ |
| T-112 | macOS `GraciaMacPlayerView`(SplatsSceneView 래핑) + 재생·탐색·배속 동기화 | ✅ 데모 2편 스트리밍 재생 확인 |
| T-113 | visionOS Compositor Services 렌더러 포팅(렌더 루프·RenderLink·레이어 설정·배치·양손 핀치) | ✅ 빌드 / 🧪 실기기 |
| T-114 | Gracia 데모 카탈로그 10편(스트리밍 엔드포인트 + 공개 토큰), 라이선스 배너, `.mint/.sog` 가져오기 | ✅ |
| T-115 | 라이브러리 선택 구조(`LibraryItemID`)로 두 렌더 경로 통합, 전환 버그(`loadedItem`) 수정 | ✅ 자동 전환 시나리오 확인 |
| T-116 | README(스크린샷·구조·포맷·검증 상태·라이선스 고지), LICENSE(Apache-2.0), NOTICE, .gitignore | ✅ |
| T-117 | Vision Pro 에서 Gracia 몰입 공간 실측(스테레오·핀치 배치·mixed/full·스트리밍 버퍼링) | 🧪 |
| T-118 | Gracia `.mint` 의 오디오 트랙(`Scene.audioData`) 재생 동기 | ⬜ |
| T-101 | 접지 그림자(GroundingShadowComponent) 옵션 | ⬜ |
| T-102 | LiDAR 바닥 스냅(SceneReconstruction 레이캐스트) | ⬜ |
| T-103 | 고차 SH(degree 1–3) 파싱·전달, 색 공간 옵션 | ⬜ |
| T-104 | 시퀀스 fps 사용자 조정, 시작/끝 트림 | ⬜ |
| T-105 | 오류 UX(한도 초과·파싱 실패) 알림 + 로그 | ⬜ |
| T-106 | 단위 테스트(파서·레이아웃·플레이어) Swift Testing | ⬜ |

## M2 — 성능

| ID | 태스크 | 상태 |
|---|---|---|
| T-201 | 시퀀스 프리페치 깊이·메모리 상한 적응 | ⬜ |
| T-202 | 저불투명 스플랫 컬링, 스플랫 수 상한 적응(품질 단계) | ⬜ |
| T-203 | 프레임 생성·파싱 최적화(디버그 빌드에서 16k–22k 스플랫 39–68 ms, 릴리스 측정 필요) / 디코드 HUD 는 있음 | ⬜ |

## M3 — 컨테이너·스트리밍

| ID | 태스크 | 상태 |
|---|---|---|
| T-301 | `.mudae` 포맷 명세(키프레임+델타, 양자화) | ⬜ |
| T-302 | macOS CLI 인코더(PLY 시퀀스 → .mudae) | ⬜ |
| T-303 | 앱 디코더 + HTTP range 스트리밍 소스 | ⬜ |
| T-304 | 품질 단계(고/경량) 선택 | ⬜ |

## M4 — 확장

| ID | 태스크 | 상태 |
|---|---|---|
| T-401 | 원격 카탈로그(JSON) | ⬜ |
| T-402 | 공간 오디오 트랙 동기 | ⬜ |
| T-403 | SharePlay 동시 감상 | ❌ (개인 팀 제약) |

## 결정 기록

- 2026-10-23 `.mint` 를 RealityKit 경로로 변환하지 않는다(라이선스 금지 + 바이너리 디코더). Gracia SDK 를 두 번째 렌더 경로로 통합한다.
- 2026-10-23 시뮬레이터 지원 중단(`SUPPORTED_PLATFORMS = macosx xros`). Gracia xcframework 와 네이티브 스플랫 모두 시뮬 SDK 에 없다.
- 2026-10-23 Gracia 직접 링크 대신 스트리밍 엔드포인트 + 공개 데모 토큰 사용(직접 링크는 Cloudflare 403).

- 2026-10-22 네이티브 경로는 `#if !targetEnvironment(simulator)` 로만 컴파일. 시뮬레이터 SDK 에 타입이 없기 때문.
- 2026-10-22 스플랫 수가 프레임마다 달라도 버퍼를 재할당하지 않고 남는 슬롯을 숨긴다(opacity logit −30).
- 2026-10-22 외부 4DGS 샘플이 없어 프로시저럴 샘플로 재생 경로를 검증한다.
