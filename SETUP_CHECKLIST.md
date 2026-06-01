# 신규 Xcode 프로젝트 초기 세팅 체크리스트

PathDock 개발 중 뒤늦게 발견했던 함정들을 정리한 체크리스트.
새 macOS 앱을 만들거나 이 프로젝트를 포크할 때 한 번씩 확인한다.

## 버전 / 빌드 번호

- [ ] **Info.plist 의 버전 키를 변수 참조로 둔다** (직접 하드코딩 금지)
  ```xml
  <key>CFBundleShortVersionString</key>
  <string>$(MARKETING_VERSION)</string>
  <key>CFBundleVersion</key>
  <string>$(CURRENT_PROJECT_VERSION)</string>
  ```
  - 하드코딩하면 Xcode General 탭(=`MARKETING_VERSION` / `CURRENT_PROJECT_VERSION`)에서
    버전을 바꿔도 **아카이브 산출물에 반영되지 않고 이전 값(예: 1.0 (1))으로 빌드**된다.
  - 커밋 `63fc1d8` 에서 실제로 이 문제를 고쳤다.
- [ ] 버전 올릴 때: Xcode General 탭 또는
  ```bash
  agvtool new-marketing-version 1.1.0
  agvtool new-version -all 3
  ```

## 번들 식별자

- [ ] `PRODUCT_BUNDLE_IDENTIFIER` 가 의도한 공개용 값인지 확인 (사내 도메인 노출 금지)
  - PathDock 은 `com.wannypark.pathdock`
- [ ] Keychain service 식별자 등 코드 내 하드코딩된 번들 ID 가 일치하는지 확인
  (`SecurityStore` 의 `com.wannypark.pathdock.masterkey`)

## 권한 / 엔타이틀먼트

- [ ] App Sandbox 필요 여부 결정. PathDock 은 Terminal/iTerm 제어를 위해 **Sandbox OFF**.
- [ ] AppleScript 로 외부 앱을 제어하면 `NSAppleEventsUsageDescription` (사용 설명) 필수.
- [ ] `LSMinimumSystemVersion` 이 실제 최소 타겟과 일치하는지.

## iCloud (백업/복원 기능 사용 시)

- [ ] **Signing & Capabilities → + Capability → iCloud → iCloud Documents** 체크
- [ ] 컨테이너 `iCloud.com.wannypark.pathdock` 가 목록에 있고 선택돼 있음 (자동 서명이면 Xcode 가 보통 자동 등록)
- [ ] `PathDock.entitlements` 에 다음 키가 있는지 (`f81d1d4` 에서 추가):
  - `com.apple.developer.icloud-container-identifiers`
  - `com.apple.developer.icloud-services = CloudDocuments`
  - `com.apple.developer.ubiquity-container-identifiers`
- [ ] `Info.plist` 의 `NSUbiquitousContainers` 가 선언돼 있는지 (Finder iCloud Drive 에 "PathDock" 폴더 노출용)
- [ ] **정식 서명 빌드(⌘R 또는 Archive)** 로만 iCloud 가 활성 — `CODE_SIGNING_ALLOWED=NO` 빌드는 엔타이틀먼트가 빠져 런타임 비활성

> iCloud 동작 검증: 앱 첫 백업 실행 후 **Finder → iCloud Drive 에 "PathDock" 폴더**, **시스템 설정 → Apple 계정 → iCloud → iCloud Drive 사용 앱** 에 항목이 등록되면 정상.

## 빌드 검증

- [ ] `xcodebuild -project … -scheme … -configuration Debug build` 가 `** BUILD SUCCEEDED **`
- [ ] 아카이브 후 `Info.plist` 의 `CFBundleShortVersionString` / `CFBundleVersion` 이
  의도한 값으로 치환됐는지 확인:
  ```bash
  /usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" -c "Print :CFBundleVersion" \
    "<산출물>/PathDock.app/Contents/Info.plist"
  ```

## 공개 저장소 전 점검

- [ ] `.gitignore` 에 에이전트 도구 부산물(`.claude/`, `.claude-flow/`, `ruvector.db` 등),
  빌드 산출물, `xcuserdata/` 가 포함됐는지.
- [ ] 소스/문서에 실제 경로(`/Users/<name>/…`), 사내 프로젝트명이 남아있지 않은지.

## GitHub Actions 자동 배포

워크플로 두 개가 `.github/workflows/` 에 있다.

| 파일 | 트리거 | 동작 |
|---|---|---|
| `ci.yml` | master push / PR / 수동 | `xcodebuild Debug build` + `swift Tests/run_unit_tests.swift` (빌드+회귀만, 산출물 없음) |
| `release.yml` | `v*` 태그 push / 수동 | Release 빌드 → **ad-hoc 재서명** → `ditto` 압축 → GitHub Releases 에 `PathDock-x.y.z.zip` 첨부 |

### 새 릴리즈 만들기

```bash
git tag v1.2.3
git push origin v1.2.3
# → Actions 가 자동으로 빌드/패키징/Release 생성
```

수동: GitHub Actions → Release → Run workflow → tag 입력.

### 서명 정책 (현재: 미서명 + ad-hoc 재서명)

- [ ] `release.yml` 의 "Ad-hoc re-sign" 단계가 `codesign --force --deep --sign -` 인지 확인
  (`--remove-signature` 로 두면 Apple Silicon amfi 가 실행을 차단)
- [ ] Actions 로그에서 `codesign --verify` 가 `valid on disk` + `satisfies its Designated Requirement` 출력하는지
- [ ] 배포 후 사용자 머신(특히 Apple Silicon)에서 다운로드 → /Applications 이동 → 더블클릭 → "그래도 열기" 한 번으로 정상 실행되는지 검증

### 권한

- [ ] 레포 Settings → Actions → General → **Workflow permissions = "Read and write permissions"**
  (`gh release create` 가 contents:write 권한 필요)

### 정식 서명·공증으로 업그레이드할 때 (선택)

Apple Developer Program 가입자가 Gatekeeper 통과까지 자동화하려면 후속 작업:

- Developer ID Application 인증서(.p12) + 비밀번호를 GitHub Secrets 에 등록
- Notarytool API Key (Issuer ID / Key ID / .p8) Secrets 등록
- `release.yml` 의 "Ad-hoc re-sign" 단계를 Developer ID 서명으로 교체 →
  `xcrun notarytool submit --wait` → `xcrun stapler staple`
- 그 시점에 README 의 "그래도 열기" 안내는 삭제 가능
