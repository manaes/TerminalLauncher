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
