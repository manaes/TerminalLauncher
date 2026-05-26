# PathDock

자주 사용하는 작업 디렉토리를 등록해두고 **더블클릭** 한 번으로 그 경로에 `cd` 된 새 Terminal 창을 띄우는 macOS 런처.

> 사내/개인용 (App Sandbox OFF, Mac App Store 배포 대상 아님)

## 주요 기능

- **두 가지 항목 타입**: 명령어 / 원격연결(SSH·VNC) — 추가 시트 상단 Picker 에서 선택
- 리스트에서 타입별 아이콘 + 뱃지(SSH=초록, VNC=파랑) 구분
- 컨텍스트 메뉴: 편집 / 실행 / 복제 / 위/아래 이동 / 삭제
- 드래그&드롭으로 순서 변경
- 우측상단 "새 터미널" 버튼 — 빈 Terminal 새 창 열기

### 명령어 타입
- 경로 + 이름 + **진입 직후 실행할 명령어셋** 을 묶어 저장
- 더블클릭 → Terminal.app 새 창에서 `cd '경로' && cmd1 && cmd2 ...` 실행
- 명령어가 비어 있으면 `cd` 까지만 수행
- 작은따옴표/공백이 포함된 경로도 안전하게 escape

### 원격연결 타입 (SSH / VNC)
- 공통 필드: 이름 / 주소 / 포트 / 사용자명 / 메모
- **SSH**: 인증 방식 선택 — 키파일(첨부 시스템에 저장, 실행 시 평문 임시 + chmod 600) 또는 패스워드
  - 더블클릭 → Terminal 새 창에서 `ssh user@host -p port [-i keyfile]`
  - 패스워드 모드는 자동입력이 표준 ssh 에서 불가하므로, **패스워드를 클립보드에 자동 복사** + 안내 echo 가 ssh 앞에 붙음 (사용자는 프롬프트에서 ⌘V)
  - **`~/.ssh/config` 자동 인식**: 시트 최상단 "ssh config" 버튼 → 등록된 Host 를 선택하면 항목 이름·HostName·Port·User·IdentityFile 이 폼에 채워짐. IdentityFile 은 PathDock 첨부 시스템으로 자동 import (10MB 상한, 암호화 모드면 자동 암호화). 와일드카드(`Host *`) / `Match` / `Include` 는 제외
  - **추가 옵션**: SSH 폼의 "추가 옵션" 섹션에 한 줄에 하나씩 `Key Value` 형식으로 입력하면 실행 시 `-oKey=Value` 로 변환되어 ssh 인자에 합성. ssh config 에서 가져올 때 PathDock 이 매핑하지 않는 키들(`HostKeyAlgorithms`, `PubkeyAcceptedAlgorithms`, `ServerAliveInterval` 등)이 여기로 자동 채워짐 → 레거시 호스트 키 호환 등 해결에 사용
- **VNC**: 패스워드 옵션만
  - 더블클릭 → `open "vnc://[user[:pass]@]host[:port]"` 로 macOS 화면 공유 / 등록된 vnc 핸들러 호출
  - 사용자명/패스워드는 percent-encoding 으로 안전하게 escape
- **명령어에 파일 첨부**: 명령어 입력 영역에 파일을 끌어다 놓으면 커서 위치에 `{{att:<uuid>}}` 토큰이 삽입되고, 실행 시 평문 임시 파일 경로로 치환된다 (단일 파일 최대 10MB)
- **저장 데이터 암호화 (선택)**: AES-GCM-256 + PBKDF2-SHA256(600k iter) + per-file nonce + 마스터키 검증 토큰. Keychain 에 마스터키를 저장해 매번 비밀번호를 묻지 않음
- **첫 실행 다이얼로그**: "암호화 활성화" 또는 "암호화하지 않기" 중 선택. 한 번 정한 모드는 고정
- **메뉴 → 설정**: 비밀번호 초기화(전체 데이터 폐기) / Export / Import(`.pathdock` 단일 파일)

## 요구 사항

- macOS 13 Ventura 이상
- Xcode 15+
- Swift 5.0+

## 빌드 및 실행

### Xcode 에서

1. `9_TerminalLauncher/TerminalLauncher.xcodeproj` 더블클릭
2. 스킴 `PathDock` 선택 후 `⌘R`

### 커맨드라인

```bash
cd path/to/9_TerminalLauncher
xcodebuild -project TerminalLauncher.xcodeproj -scheme PathDock -configuration Debug build
```

빌드 산출물은 `~/Library/Developer/Xcode/DerivedData/.../Build/Products/Debug/PathDock.app` 에 생성된다. 더블클릭 또는 `open ./PathDock.app` 로 실행.

## 첫 실행 시 자동화 권한

PathDock 은 Terminal.app 을 AppleScript 로 제어한다. 첫 실행 시 macOS 가 다음 권한을 요청한다.

> "PathDock"이(가) "Terminal" 앱을 제어하도록 허용하시겠습니까?

**허용** 을 눌러야 정상 동작한다. 거부한 경우 시스템 설정에서 다시 켤 수 있다.

```
시스템 설정 → 개인 정보 보호 및 보안 → 자동화 → PathDock → Terminal 체크
```

## 데이터 저장 위치

```
~/Library/Application Support/PathDock/
├── security.plist     # 모드(plain|encrypted) + 솔트 + verifier
├── entries.json       # plain 모드: 평문 JSON
├── entries.enc        # encrypted 모드: { nonce, tag, ciphertext }
├── attachments/<uuid> # 첨부 파일 (모드에 따라 평문 / nonce|ct|tag)
└── decrypted/         # 실행 시 평문 임시 (다음 앱 시작 시 1회 정리)
```

- **plain 모드**: 직접 편집 가능. 단, 앱 실행 중엔 디바운스 저장에 덮어쓰일 수 있으니 앱 종료 후 수정.
- **encrypted 모드**: Keychain 항목 `com.wannypark.pathdock.masterkey` (account: `default`, AccessibleWhenUnlockedThisDeviceOnly).

## 보안 / 첫 실행

첫 실행 시 다이얼로그에서 다음 중 하나를 선택한다.

| 선택 | 동작 |
|---|---|
| 암호화 활성화 | 입력한 암호 → PBKDF2-SHA256 (600,000 iter) → AES-256 키 도출 → Keychain 저장. entries 와 첨부가 AES-GCM 으로 암호화되어 디스크에 저장됨 |
| 암호화하지 않기 | 모든 IO 가 평문. UX 동일 |

**한 번 정한 모드는 고정.** 변경하려면 메뉴 → 설정 → **비밀번호 초기화** (전체 데이터 폐기) 후 첫 실행 다이얼로그로 복귀.

### Export / Import (`.pathdock` 단일 파일)

- **Export**: 별도 비밀번호 입력 → entries + 첨부 전체를 단일 `.pathdock` 파일로 패키징
- **Import**: 파일 선택 → 그 파일의 비밀번호 입력 → 복호화 → **현재 마스터키로 재암호화하여 기존 리스트에 병합(append)**
- 파일 포맷: `magic(8) + version(2) + salt(16) + nonce(12) + ciphertext + tag(16)` (외부 의존 없는 자체 정의)

### 첨부

- 명령어 입력 영역에 파일을 끌어다 놓으면 커서 위치에 `{{att:<uuid>}}` 토큰이 삽입된다
- 단일 파일 **10MB 상한** (초과 시 첨부 거부 알럿)
- 실행 시 평문이 `decrypted/<run-uuid>/<originalName>` 에 잠시 풀려 명령어에 셸 escape 된 경로로 치환된 뒤, Terminal 창에서 실행
- 평문 임시 파일은 **다음 앱 시작 시 1회** 자동 정리

## 사용 예시

| 이름 | 경로 | 명령어셋 |
|---|---|---|
| Example Project | `~/Example/Path` | `bundle install`<br>`bundle exec fastlane test` |
| Plain cd | `~/Example/Another` | (비워둠 → cd 만) |
| Log Tail | `/var/log/example` | `tail -f main.log` |

> 명령어셋은 한 줄에 하나의 명령으로 입력한다. 빈 줄은 무시된다. 줄 단위로 `&&` 로 묶여 셸에 전달된다.

## 폴더 구조

```
9_TerminalLauncher/
├── README.md
├── MANUAL_TESTS.md
├── TerminalLauncher.xcodeproj/
├── Tests/run_unit_tests.swift   # standalone 단위 회귀 (swift Tests/run_unit_tests.swift)
└── PathDock/
    ├── PathDockApp.swift              # @main, 상태머신 (firstRun / locked / ready)
    ├── Models/
    │   ├── PathEntry.swift            # attachments 필드 포함
    │   ├── Attachment.swift
    │   └── SecurityConfig.swift
    ├── Stores/
    │   ├── EntryStore.swift           # entries.json ↔ entries.enc 모드 분기
    │   ├── AttachmentStore.swift      # 10MB 상한, 모드별 IO, decrypted cleanup
    │   └── SecurityStore.swift        # security.plist + Keychain + KDF + verifier
    ├── Services/
    │   ├── TerminalLauncher.swift     # AppleScript + 토큰 치환
    │   ├── CryptoService.swift        # AES-GCM + PBKDF2 + LockedData(mlock)
    │   ├── ExportService.swift        # .pathdock 패키지 생성
    │   └── ImportService.swift        # .pathdock 복호화 → 재암호화 → 병합
    ├── Views/
    │   ├── ContentView.swift
    │   ├── EntryRow.swift
    │   ├── EntryEditorSheet.swift
    │   ├── DraggableCommandEditor.swift  # NSTextView + fileURL drop
    │   ├── FirstRunSetupView.swift
    │   ├── UnlockView.swift
    │   ├── SettingsView.swift            # 비번 초기화 / Export / Import
    │   ├── ExportPasswordSheet.swift
    │   └── ImportPasswordSheet.swift
    ├── Resources/
    │   ├── Info.plist
    │   └── PathDock.entitlements
    └── Assets.xcassets/
```

## 알려진 한계

- iTerm2 미지원 (v1 은 Terminal.app 만)
- 메뉴바 상주 모드 / 글로벌 단축키 미지원
- SSH 원격 프로필 미지원
- 명령어 실행 결과 캡처 안 함 (Terminal 창에 그대로 보임)
