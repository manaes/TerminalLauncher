# 작업 기록 — 2026-05-30: iCloud 백업/복원 + 버그 수정

> 브랜치: `master` · 기능 커밋: `f81d1d4` (이 문서는 별도 커밋) · 작성: Claude Code

다른 컴퓨터에서 이어서 작업하기 위한 핸드오프 문서. 오늘 한 일, 현재 상태, 이어서 할 일을 정리한다.

---

## 0. 한 줄 요약

PathDock 에 **iCloud 백업/복원**(전용 컨테이너, 원탭 + 자동) 기능을 추가하고, 항목 **복제/Import** 시 SSH·VNC 정보가 사라지던 버그와 **KDF 메인스레드 블로킹**을 수정했다. 빌드 성공·테스트 151개 통과·코드리뷰 반영 완료.

---

## 1. 버그 수정

### 1-1. 복제 시 SSH/VNC 항목이 빈 "명령어"로 변질 (major)
- **파일**: `PathDock/Stores/EntryStore.swift` (`duplicate`)
- **원인**: `PathEntry` 이니셜라이저 호출 시 `kind` 와 원격 필드(host/port/username/auth/password/keyAttachmentId/sshExtraOptions)를 누락 → 기본값(`.command`, nil)로 떨어짐.
- **수정**: 모든 필드를 보존하는 **깊은 복사**. 첨부는 새 UUID 로 디스크 재기록하고, 명령어 본문의 `{{att:uuid}}` 토큰과 `keyAttachmentId` 를 새 id 로 remap. 첨부 복사 실패 시 해당 id 를 매핑에서 제외(dangling 방지).

### 1-2. Import/복원 시 동일한 누락 (major)
- **파일**: `PathDock/Services/ImportService.swift`
- **수정**: `decodeManifest`(백그라운드 가능) / `apply(into:mode:)`(@MainActor, merge/replace) 로 리팩터링. `apply` 가 `kind`·원격 필드를 보존하고 `keyAttachmentId` 를 idMap 으로 remap. **첨부 쓰기 실패 시 idMap 정리**(코드리뷰 반영 — `duplicate` 와 대칭, dangling keyAttachmentId/메타 방지). idMap 순회 중 변경 크래시도 키 스냅샷으로 회피.

---

## 2. 개선

- **KDF 백그라운드 오프로딩**: `SecurityStore.setupEncrypted/unlock` 을 `async` 로 바꾸고 PBKDF2(600k)를 `deriveKeyOffMain`(Task.detached)으로 메인 액터 밖에서 수행 → 첫 실행/잠금해제 중 스피너가 멈추지 않음. `LockedData` 는 `@unchecked Sendable`(불변 + 읽기 전용 + deinit zero-fill 이라 안전).
- **백업 시 첨부 복호화도 백그라운드**: `AttachmentStore.read` 를 `nonisolated` 로(불변 let 만 접근). `ExportService.buildManifest(entries:attachmentStore:)` 가 백그라운드에서 첨부 복호화 + manifest 구성.
- **iTerm SSH 자동입력 대기시간 설정화**: `Preferences.itermAutoTypeDelaySeconds`(기본 2.0, 0.5~10초), `ITermLauncher` 에서 사용, 설정 화면 Stepper 노출. (호스트 키 yes/no 프롬프트가 먼저 뜰 때 늘릴 수 있게)
- **Preferences 하위호환**: 커스텀 `init(from:)` + `decodeIfPresent` 로 구버전 `preferences.json`(새 키 없음)도 기본값으로 채워 디코드 실패/설정 초기화 방지.
- **KDF 반복수 단일 출처**: `CryptoService.defaultKDFIterations`(nonisolated)로 통일 (Swift 6 isolation 경고 제거).

---

## 3. iCloud 백업/복원 (신규 기능)

설계 결정(사용자 선택): **전용 iCloud 컨테이너** + **Keychain 백업 비번(원탭)** + **복원 시 덮어쓰기/병합 선택** + **수동 + 자동 백업**.

### 신규 파일
- `PathDock/Services/CloudBackupService.swift` — ubiquity 컨테이너(`iCloud.com.wannypark.pathdock`) Documents IO. `documentsURL`/`backupFileURL`/`isAvailable`/`writeBackup`/`readBackup`(다운로드 트리거+폴링)/`backupInfo`/`deleteBackup`. NSFileCoordinator 로 조율. 전부 백그라운드 호출 전제.
- `PathDock/Stores/CloudBackupStore.swift` — `@MainActor ObservableObject` 코디네이터. 가용성, `enableBackup`(Keychain 비번 저장+즉시 백업), `backupNow`, `restore(mode:)`, EntryStore 변경 관찰 → 5초 디바운스 자동 백업. (진행 중 요청은 pending 재시도, 복원 중 자동백업 억제 — 코드리뷰 반영)
- `PathDock/Views/CloudBackupPasswordSheet.swift` — 백업 비번 최초 설정 시트.

### 동작
- 백업 파일은 Export 와 동일한 `.pathdock`(AES-GCM + PBKDF2) → **iCloud 에는 암호화 바이트만** 올라감.
- 설정(⌘,) → "iCloud 백업" 섹션:
  - iCloud 불가: "사용 불가" + 다시 확인
  - 미설정: "iCloud 백업 설정…" (비번 1회 → Keychain)
  - 설정 후: 마지막 백업 시각 · "변경 시 자동 백업" 토글 · **지금 백업**(수동) · **iCloud 에서 복원…**(덮어쓰기/병합) · 백업 해제
- 복원 시 첨부는 현재 마스터키로 재암호화, id/토큰/keyAttachmentId remap.

### 설정 파일 변경
- `PathDock/Resources/PathDock.entitlements` — `icloud-container-identifiers` / `icloud-services=CloudDocuments` / `ubiquity-container-identifiers`.
- `PathDock/Resources/Info.plist` — `NSUbiquitousContainers`(IsDocumentScopePublic=true, Name=PathDock) → Finder iCloud Drive 에 "PathDock" 폴더 노출.
- `SecurityStore` — 백업 비번 Keychain CRUD(`com.wannypark.pathdock.backuppw`), `resetAll` 시 함께 삭제.
- `project.pbxproj` — 신규 3파일 등록.

---

## 4. 코드리뷰(멀티 에이전트 워크플로) 반영

22개 에이전트 적대적 리뷰 → 확정 결함(중복 제거 6종) 전부 수정:
- ImportService 첨부 실패 시 idMap 정리 / 백업 시 첨부 복호화 백그라운드화 / 진행 중 자동백업 유실 방지(pending) / 복원 직후 자기 재업로드 루프 억제 / 백업 삭제·불가 시 `lastBackupAt` 정리 / 가용성 확인의 디렉토리 생성 부작용 제거.

---

## 5. 검증

- `xcodebuild -scheme PathDock -configuration Debug CODE_SIGNING_ALLOWED=NO build` → **BUILD SUCCEEDED, 경고 0**.
- `swift Tests/run_unit_tests.swift` → **151 passed / 0 failed** (복제·Import·Preferences 회귀 32개 신규 포함).

> 주의: standalone 테스트는 production 코드를 import 하지 않고 로직을 미러링한다(기존 프로젝트 방식). 의도/계약을 잠그는 용도이며, 실제 동작은 빌드 + 수동 테스트(`MANUAL_TESTS.md` §17, §18)로 확인.

---

## 6. 빌드 / 실행 + iCloud 1회 설정

CLI 컴파일 확인(서명 없이):

    xcodebuild -project TerminalLauncher.xcodeproj -scheme PathDock -configuration Debug \
      -destination 'generic/platform=macOS' CODE_SIGNING_ALLOWED=NO build

단위 회귀:

    swift Tests/run_unit_tests.swift

**iCloud 가 실제로 동작하려면(중요):**
1. Xcode 에서 본인 Apple 계정으로 열고, **Signing & Capabilities → + Capability → iCloud → iCloud Documents** 체크, 컨테이너 `iCloud.com.wannypark.pathdock` 선택. (엔타이틀먼트엔 이미 선언돼 있고, 자동 서명이면 Xcode 가 대부분 자동 등록)
2. 맥이 **iCloud Drive 에 로그인**돼 있어야 함.
3. **정식 서명 빌드(⌘R)** 여야 함 — `CODE_SIGNING_ALLOWED=NO` 빌드는 엔타이틀먼트가 빠져 런타임 iCloud 가 비활성.

---

## 7. "iCloud 동기화 앱"으로 보이는 조건

위 1~3 을 만족하고 앱이 한 번 실행되어 첫 백업을 쓰면:
- **Finder → iCloud Drive 에 "PathDock" 폴더** 노출(`PathDock-backup.pathdock`).
- **시스템 설정 → Apple 계정 → iCloud → iCloud Drive 사용 앱** 목록에 등록.
- 같은 Apple ID 기기 간 동기화(다른 기기에서 복원 가능).

미서명/미로그인/첫 백업 전이면 앱·폴더가 안 보이는 게 정상.

---

## 8. 현재 상태 (이 작업 직후)

- 작업은 **`master` 브랜치**에 통합됨(워크트리·feat 브랜치 정리 완료, 단일 브랜치).
- 기능 코드 커밋: `f81d1d4`. 이 문서는 별도 커밋.
- `master` 를 origin 에 **푸시**(다른 컴에서 `git pull` 로 이어서 작업).
- 로컬 `.claude/settings.json` 에 `worktree.bgIsolation: "none"`(git 무시됨, 이 머신 한정 — 다른 컴엔 영향 없음).

---

## 9. 다른 컴퓨터에서 이어서 하기

    git pull            # 또는 git clone <repo>
    git checkout master
    # Xcode 에서 iCloud capability 1회 설정(6번) 후 ⌘R

---

## 10. 알려진 한계 / 다음 단계 후보

- iCloud 백업은 단일 파일(덮어쓰기), 버전 히스토리/충돌 병합 없음(마지막 백업 우선).
- iTerm2 SSH 자동입력은 고정 delay 휴리스틱(설정 조정 가능). 호스트 키 최초 yes/no 프롬프트가 먼저 뜨면 어긋날 수 있음.
- 평문(plain) 모드에서는 원격 패스워드가 디스크에 평문 저장(README 고지). Terminal 백엔드 SSH 패스워드는 클립보드 경유.
- 테스트가 production 코드 미러(드리프트 위험) — 정식 XCTest 타깃 도입 검토 여지.
- (후보) iCloud 백업 다중 슬롯/타임스탬프 히스토리, 복원 전 미리보기, 메뉴바 상주.
