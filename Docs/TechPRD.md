# 무대 (Mudae) — 4D 가우시안 스플랫 볼류메트릭 뷰어 · 테크 PRD v0.1

작성일 2026-10-22 · 대상 플랫폼 visionOS 27 (주), macOS 27 (개발·검증), iOS 27 (빌드만) · 상태: M0 구현 중

## 1. 한 줄 요약

Gracia: 4DGS viewer 처럼, **움직이는 가우시안 스플랫(4DGS) 캡처를 Apple Vision Pro 로 내 방에 실물 크기로 세워 두고 걸어 다니며 보는 앱**. RealityKit 27 의 네이티브 `GaussianSplatComponent` 로 렌더링하고, 프레임 시퀀스를 CPU 에서 `LowLevelBuffer` 에 갱신해 4D 재생을 구현한다.

## 2. 참고 모델: Gracia 가 하는 일

| Gracia 기능 | 설명 | 무대 M0 | 이후 |
|---|---|---|---|
| 완전 볼류메트릭 | 스테레오 영상이 아니라 임의 시점에서 걸어 다니며 감상 | ✅ 네이티브 3DGS 렌더 | — |
| 4D(시간축) | 정지 스캔이 아니라 움직이는 캡처 | ✅ 프레임 시퀀스 재생(재생·일시정지·탐색·배속·반복) | 키프레임+델타 코덱 |
| 패스스루 배치 / 완전 몰입 | 내 방에 두거나(mixed) 장면 속으로 들어감(full) | ✅ 두 몰입 모드 + 드래그 이동·핀치 확대 | 바닥 자동 스냅(LiDAR) |
| 콘텐츠 라이브러리 | 25+ 캡처 번들/스트리밍 | ✅ 프로시저럴 샘플 3종 + PLY/시퀀스 폴더 가져오기 | 원격 카탈로그 |
| 스트리밍·다운로드 | 75 Mbps 고화질(≈12만 스플랫/프레임) / 17 Mbps 경량(≈1.5만) | ❌ | HTTP range 스트리밍, 품질 단계 |
| 압축 코덱 | 키프레임 + 모션 델타 전송 | ❌ | 자체 컨테이너(.mudae) 설계 |

출처: [MacTech](https://www.mactech.com/2026/06/22/gracia-launches-first-4d-gaussian-splatting-app-for-the-apple-vision-pro/), [Radiance Fields](https://radiancefields.com/gracia-brings-its-streamable-4dgs-volumetric-videos-to-apple-vision-pro), [UploadVR](https://www.uploadvr.com/gracia-moving-volumetric-captures-now-streamable/), [App Store](https://apps.apple.com/us/app/gracia-4dgs-viewer/id6773024890)

## 3. 목표 / 비목표

**목표**
- G1. 3DGS PLY 한 장을 Vision Pro 공간에 네이티브 품질로 띄운다.
- G2. PLY 프레임 폴더(시퀀스)를 4D 로 끊김 없이 재생한다(목표 30 fps, 프레임당 ≤ 10만 스플랫).
- G3. Gracia 식 UX: 라이브러리 → 선택 → "내 방에 배치" 또는 "완전 몰입" → 플레이어 컨트롤.
- G4. 외부 의존성 0, Swift/SwiftUI/RealityKit 만으로 구현. 시뮬레이터에서도 폴백으로 동작 확인 가능.

**비목표 (이번 범위 밖)**
- 캡처·학습 파이프라인(멀티뷰 촬영 → 4DGS 학습)은 만들지 않는다. 외부에서 만든 PLY 를 소비한다.
- Gracia 의 독점 코덱·CDN 재현. 스트리밍은 M3 에서 자체 포맷으로 별도 설계.
- SharePlay/멀티유저, 사운드 동기화(M4 후보).

## 4. 사용자 시나리오

1. 앱을 열면 라이브러리 창에 샘플("스트리트 댄서", "파동 바닥", "별빛 나선")과 가져온 파일이 보인다.
2. 카드를 고르면 창 안에 축소 미리보기와 플레이어가 뜬다. 재생/탐색/배속/반복을 조절한다.
3. "내 방에 배치"를 누르면 패스스루 위 1.5 m 앞에 실물 크기로 선다. 드래그로 옮기고 핀치로 키운다.
4. "완전 몰입"으로 바꾸면 방이 어두워지고 장면만 남는다. 디지털 크라운으로 돌아온다.
5. 툴바 "가져오기"로 `.ply` 한 장 또는 PLY 가 들어 있는 폴더(=시퀀스)를 고른다. 위아래가 뒤집혀 보이면 "상하 반전" 토글.

## 5. 기능 요구사항

| ID | 요구사항 | 우선순위 |
|---|---|---|
| F1 | 라이브러리: 샘플 + 가져온 항목 목록, 제목/프레임 수/fps/스플랫 수 표시 | P0 |
| F2 | 플레이어: 재생·일시정지, 프레임 슬라이더, 배속(0.25–2×), 반복, 현재 시간 | P0 |
| F3 | 배치: mixed/full 몰입 전환, 드래그 이동(바닥 높이 유지), 핀치 확대, 상하 반전, 바닥 맞춤 | P0 |
| F4 | 가져오기: 3DGS PLY(binary LE/BE, ascii), 폴더 시퀀스(이름순, `sequence.json` 의 fps) | P0 |
| F5 | 렌더 경로 자동 선택: 실기기·macOS = 네이티브 스플랫, 시뮬레이터 = 색 버킷 메시 폴백, UI 에 표시 | P0 |
| F6 | 상태·오류 표시(파싱 실패, 스플랫 한도 초과) | P1 |
| F7 | 자체 컨테이너 `.mudae` (키프레임 + 델타, 메타데이터) + HTTP range 스트리밍 | P2 (M3) |
| F8 | 접지 그림자(`GroundingShadowComponent`), 공간 오디오 트랙 | P2 |

## 6. 아키텍처

```
┌──────────── SwiftUI ────────────┐   ┌────────── RealityKit ──────────┐
│ ContentView(NavigationSplit)    │   │ StageView(RealityView)         │
│  ├ LibraryList                  │──▶│  └ SplatRenderer               │
│  └ StageDetail + PlayerControls │   │     ├ native: GaussianSplat    │
│ ImmersiveStageView (visionOS)   │   │     │   Component+LowLevelBuffer│
└───────────────┬─────────────────┘   │     └ fallback: bucketed mesh  │
                │ @Observable          └────────────────────────────────┘
        ┌───────▼────────┐  frame(at:)  ┌────────────────────────────┐
        │ AppModel       │─────────────▶│ SplatSource (actor)        │
        │  └ SplatPlayer │◀─SplatCloud──│  ├ PLYFileSource           │
        └────────────────┘              │  ├ PLYSequenceSource(LRU)  │
                                        │  └ ProceduralSplatSource   │
                                        └──────────┬─────────────────┘
                                                   │ PLYSplatParser
```

- **SplatCloud**: 프레임 하나. 인터리브 `Float ×16`(64 B)/스플랫 = 위치3·스케일3(log)·회전4(w,x,y,z)·불투명도1(logit)·SH0 3·패딩2. 이 레이아웃을 `GaussianSplatResource.BufferDescriptor` 가 그대로 참조하므로 복사 1회로 끝난다.
- **SplatSource**: `frameCount`, `framesPerSecond`, `frame(at:) async throws -> SplatCloud`. actor 로 구현해 파싱이 메인 액터 밖에서 돈다.
- **SplatPlayer**: `ContinuousClock` 기준 시각으로 목표 프레임을 계산(드리프트 없음), 프레임 바뀔 때만 `revision` 증가.
- **SplatRenderer**: 네이티브 경로는 `LowLevelBuffer` 를 최대 용량으로 1회 할당하고 프레임마다 `withUnsafeMutableBytes` 로 덮어쓴다(프레임워크가 버퍼를 참조하므로 리소스 재생성 없음). 프레임마다 스플랫 수가 달라도 남는 슬롯은 opacity logit −30 으로 숨긴다. 수가 용량을 넘을 때만 리소스를 재생성한다.
- **플랫폼 분기**: `#if targetEnvironment(simulator)` 에서 네이티브 타입이 SDK 에 없으므로(검증: XRSimulator SDK swiftinterface 0건, XROS/macOS 29건) 폴백만 컴파일.

## 7. 데이터 포맷

- **3DGS PLY**: `x y z`, `scale_0..2`(log), `rot_0..3`(w 먼저), `opacity`(logit), `f_dc_0..2`(SH0). `f_rest_*`(고차 SH)는 M0 에선 무시(degree 0). 색이 `red/green/blue` uchar 뿐인 포인트클라우드도 SH0 로 변환해 받는다. 스케일 없으면 log(0.005), 불투명도 없으면 logit(0.99).
- **시퀀스 폴더**: `*.ply` 를 `localizedStandardCompare` 로 정렬(0001, 0002 …). 옵션 `sequence.json`: `{ "fps": 24, "flipY": true }`.
- **좌표계**: COLMAP 계열 3DGS 는 Y 아래·Z 앞이라 거꾸로 보인다 → "상하 반전"(X 축 180° 회전) 토글, 파일 가져오기는 기본 켬. "바닥 맞춤"은 회전 후 경계상자의 최소 y 를 0 으로 옮긴다.
- **(M3) .mudae 컨테이너**: 헤더(json: fps, 프레임 수, 경계, 품질 단계) + 키프레임(양자화 스플랫 전체) + 델타(변경 인덱스 + 위치/회전/색 차분, 16-bit). HTTP range 로 청크 단위 수신.

## 8. 성능 예산

| 항목 | 예산 | 근거 |
|---|---|---|
| 프레임당 스플랫 | 네이티브 ≤ 100k(목표), 폴백 ≤ 8k 샘플링 | Gracia 고화질 120k/프레임, 프레임워크 내부 한도(초과 시 BufferResource init throw) |
| 프레임 갱신 CPU | ≤ 4 ms (memcpy 6.4 MB @100k) | 30 fps 에서 여유 |
| PLY 파싱 | 100k 스플랫 ≤ 50 ms | 시퀀스 프리페치 2 프레임 선행 |
| 메모리 | LRU 12 프레임 × 6.4 MB ≈ 77 MB | 시퀀스 소스 캐시 |

## 9. 제약·리스크

- 시뮬레이터에는 네이티브 스플랫 타입이 없다 → 폴백 메시로 흐름만 확인, 화질 검증은 macOS(My Mac) 와 실기기(Vision Pro)에서.
- 네이티브 스플랫은 Apple7 GPU 이상 필요, 장면 조명 영향 없음(캡처 당시 조명 그대로).
- 스플랫 정렬은 프레임워크가 `sortingMode`(.depth 기본)로 처리. 대량 반투명 겹침은 비용 증가 → 저불투명 스플랫 사전 컬링(M2).
- 외부 4DGS 샘플 파일이 없다 → 프로시저럴 샘플 3종으로 재생 경로를 검증하고, 사용자가 PLY 시퀀스를 넣어 실측.
- 시뮬레이터는 다른 세션(Claude Desktop)과 공유 중 → 기존 기기 건드리지 않고 generic 빌드·macOS 실행으로 검증.

## 10. 마일스톤

| M | 내용 | 완료 기준 |
|---|---|---|
| M0 | 앱 셸 + 데이터 모델 + PLY 파서 + 프로시저럴 4D 샘플 + 플레이어 + 네이티브/폴백 렌더 + 몰입 공간 + 가져오기 | visionOS 기기·시뮬·macOS 3빌드 통과, macOS 에서 네이티브 스플랫 재생 확인 |
| M1 | 실기기 QA(패스스루 배치·드래그·핀치·크라운), 접지 그림자, 바닥 스냅, 고차 SH(degree 1–3) | Vision Pro 에서 샘플 3종 + 외부 PLY 1개 정상 |
| M2 | 시퀀스 성능: 프리페치·백그라운드 파싱·저불투명 컬링·메모리 상한, 스플랫 수 적응 | 100k × 30 fps 유지 |
| M3 | `.mudae` 컨테이너 + 키프레임/델타 인코더(macOS CLI) + HTTP range 스트리밍 + 품질 단계 | 로컬 서버에서 스트리밍 재생 |
| M4 | 원격 카탈로그, 공간 오디오, SharePlay(선택) | — |

## 11. 검증 계획

- 빌드: Any visionOS Device / Any visionOS Simulator / My Mac 3종.
- 단위: PLY 파서(ascii·binary LE·BE·uchar 색), 레이아웃 오프셋, 플레이어 프레임 계산(배속·반복·탐색).
- 시각: macOS 창에서 네이티브 스플랫 재생 스크린샷, 시뮬레이터 폴백 스크린샷(차례 확인 후), 실기기 사용자 확인.

## 12. 오픈 이슈

- 버퍼를 프레임마다 CPU 로 덮어쓸 때 프레임워크가 내부 정렬 캐시를 언제 갱신하는지 공개 문서 없음 → macOS 에서 실측.
- visionOS 2D 창 안의 RealityView 미리보기는 깊이가 제한적 → 필요하면 `.volumetric` 창으로 교체.
- 이름 "무대(Mudae)" 와 번들 ID 는 사용자 확정 전 임시.
