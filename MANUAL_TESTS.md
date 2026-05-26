# PathDock 수동 테스트 체크리스트

PathDock(앱 표시명) / TerminalLauncher(Xcode 타겟) 의 수락 기준을 사람이 직접
실행해서 검증하기 위한 시나리오 모음. 항목 순서는 보통 처음 검증할 때
이 순서대로 진행하면 의존성 없이 매끄럽다.

## 사전 준비

| 항목 | 내용 |
|---|---|
| 빌드 | `xcodebuild -project TerminalLauncher.xcodeproj -scheme PathDock -configuration Debug build` 가 `** BUILD SUCCEEDED **` |
| 실행 | Xcode 에서 PathDock 스킴 실행, 또는 빌드 산출물의 `PathDock.app` 더블클릭 |
| 데이터 파일 | `~/Library/Application Support/PathDock/entries.json` |
| 자동화 권한 | 시스템 설정 → 개인 정보 보호 및 보안 → 자동화 → **PathDock** 항목 안의 **Terminal** 체크박스 |
| 단위 회귀 | 별도 `swift Tests/run_unit_tests.swift` 가 `passed: 119 / failed: 0` (셸 escape · 빌드 명령 합성 · EntryStore 정합성 · 토큰 정규식 · 10MB 경계 · `.pathdock` 헤더 · SSH 셸 합성 · VNC URL 합성 · SSH config 파서 + extraOptions · `-oKey=Value` 합성 · Preferences · ITermSession 직렬화) |

> 모든 시나리오는 "사전 준비" 의 `entries.json` 위치를 알고 있다고 가정한다.
> 매 시나리오 시작 전에는 가능하면 앱을 종료한 뒤 `entries.json` 을 백업/삭제하고
> 깨끗한 상태에서 시작한다. (예: `mv ~/Library/Application\ Support/PathDock/entries.json{,.bak}`)

---

## 1. 빈 상태 / 항목 추가 (수락 기준: 빈 리스트 + `+`, 시트, 폴더 선택, 저장 후 즉시 반영)

| # | 시나리오 | 조작 | 기대 결과 | 확인 방법 |
|---|---|---|---|---|
| 1-1 | 첫 실행 시 빈 상태 표시 | `entries.json` 삭제 후 앱 실행 | "등록된 경로가 없습니다" 메시지 + 우측 상단 `+` 버튼 노출 | 화면 육안 확인 |
| 1-2 | `+` 버튼 → 시트 | 우측 상단 `+` 클릭 | 추가 시트(EntryEditorSheet) 가 모달로 표시. 이름/경로/명령어/메모 필드 존재 | 화면 육안 확인 |
| 1-3 | NSOpenPanel 폴더 선택 | 시트에서 "폴더 선택…" 버튼 클릭 → 임의 디렉토리(예: `~/Desktop`) 선택 | 디렉토리 선택 모드 패널 → 선택 시 경로 텍스트필드에 절대 경로 반영 | 텍스트필드 값 확인 |
| 1-4 | 저장 → 리스트 반영 | 이름 "Desktop", 경로 위에서 선택된 값, 명령어 비움, 저장 | 시트가 닫히고 리스트에 1건 표시, 행에 이름·경로 보임 | 화면 + `cat "$HOME/Library/Application Support/PathDock/entries.json"` 으로 1건 존재 확인 |
| 1-5 | 디스크 영속화 | 1-4 직후 `Cmd+Q` 로 종료 후 즉시 재실행 | 동일 항목이 여전히 리스트에 표시 | applicationWillTerminate 의 flush 가 동작했음을 의미 |

---

## 2. 더블클릭 실행 (수락 기준: cd + 명령어 순차 실행, 자동화 권한 다이얼로그)

| # | 시나리오 | 조작 | 기대 결과 |
|---|---|---|---|
| 2-1 | 최초 더블클릭 시 권한 다이얼로그 | "자동화" 항목에서 PathDock → Terminal 체크박스가 **없는** 상태로 항목 더블클릭 | "PathDock이(가) Terminal을(를) 제어하도록 허용하시겠습니까?" 시스템 다이얼로그 표시 |
| 2-2 | 권한 허용 후 Terminal 새 창 | 다이얼로그 "OK" → 다시 더블클릭 (또는 다이얼로그 직후 자동 진행) | Terminal.app 활성화 + **새 창** 1개 생성, 프롬프트에 `cd '<경로>'` 가 실행된 흔적(`pwd` 결과가 등록 경로와 일치) |
| 2-3 | 명령어 셋이 있는 항목 실행 | 이름 "with-ls", 경로 `~/Desktop`, 명령어 두 줄: `ls -la`, `pwd` → 더블클릭 | 새 창에서 `cd '/Users/<u>/Desktop' && ls -la && pwd` 가 한 줄로 실행되어 `ls` 결과와 `pwd` 결과가 차례로 출력 |
| 2-4 | 명령어 비어있는 항목 | 명령어 칸 모두 비움 + 저장 → 더블클릭 | 새 창에서 `cd '<경로>'` 만 실행. 프롬프트는 등록 경로에 위치. `pwd` 로 직접 확인 가능 |
| 2-5 | 공백 줄 / 양옆 공백만 있는 줄 무시 | 명령어 칸: `""`, `"  "`, `"ls"`, `"\t"`, `"pwd"` 입력 → 저장 → 더블클릭 | 새 창에서 실행된 명령은 `cd '<경로>' && ls && pwd`. 빈/공백 줄은 무시됨 |
| 2-6 | 컨텍스트 메뉴 "실행" | 항목 우클릭 → "실행" | 더블클릭과 동일 동작 |

---

## 3. 오류 처리 (수락 기준: 경로 미존재 시 에러 다이얼로그, 자동화 권한 거부 안내)

| # | 시나리오 | 조작 | 기대 결과 |
|---|---|---|---|
| 3-1 | 존재하지 않는 경로 | 시트에서 경로를 직접 `/tmp/this-does-not-exist-xyz` 로 타이핑 → 저장 → 더블클릭 | SwiftUI Alert "실행 실패" + 메시지 "경로를 찾을 수 없습니다:\n/tmp/this-does-not-exist-xyz" 표시. **Terminal 새 창은 열리지 않음** |
| 3-2 | `~` 확장 | 시트에서 경로를 `~/Desktop` 로 타이핑 → 저장 → 더블클릭 | `~` 가 `$HOME` 으로 확장되어 정상 실행. 새 창의 `pwd` 가 `/Users/<u>/Desktop` |
| 3-3 | 자동화 권한 거부 후 실행 | 시스템 설정 → 자동화 → PathDock → Terminal 체크 해제 → 항목 더블클릭 | SwiftUI Alert "실행 실패" + "터미널 실행에 실패했습니다." 안내. 다이얼로그에 "시스템 설정 → 자동화" 안내 문구 포함 |
| 3-4 | 권한 거부 후 재허용 | 3-3 이후 시스템 설정에서 다시 Terminal 체크 → 더블클릭 | 정상적으로 Terminal 새 창이 열림. 앱 재시작 필요 없음 |

---

## 4. Shell escape (수락 기준: 작은따옴표/공백 포함 경로 정상 해석)

> 사전: 테스트용 디렉토리 만들기.
> `mkdir -p "/tmp/don't" "/tmp/My Folder/sub dir"`

| # | 시나리오 | 조작 | 기대 결과 |
|---|---|---|---|
| 4-1 | 작은따옴표 포함 경로 | 경로 `/tmp/don't` 등록 → 더블클릭 | 새 창의 `pwd` 가 `/tmp/don't`. 합성된 셸 라인은 `cd '/tmp/don'\''t'` (단위 테스트 buildShellCommand 케이스에서 회귀 검증됨) |
| 4-2 | 공백 포함 경로 | 경로 `/tmp/My Folder/sub dir` 등록 → 더블클릭 | 새 창의 `pwd` 가 `/tmp/My Folder/sub dir` |
| 4-3 | 작은따옴표 + 공백 + 명령어 | 경로 `/tmp/don't`, 명령어 `echo "hello"`, `ls` → 더블클릭 | 새 창에서 `hello` 출력 + `ls` 결과 출력. 깨진 escape 로 인한 셸 에러가 없음 |
| 4-4 | (옵션) AppleScript escape round-trip | 위 4-3 케이스를 단위 테스트로도 검증 | `swift Tests/run_unit_tests.swift` 에서 `escapeForAppleScriptDoubleQuoted` 케이스 통과 |

---

## 5. 컨텍스트 메뉴 (수락 기준: 편집/복제/위로/아래로/삭제 모두 동작)

> 사전: 항목 3개를 "A", "B", "C" 순서로 등록.

| # | 시나리오 | 조작 | 기대 결과 |
|---|---|---|---|
| 5-1 | 편집 | "B" 우클릭 → "편집…" → 이름을 "B2" 로 변경 → 저장 | 리스트에 "A", "B2", "C". `entries.json` 에도 `"name": "B2"` 반영 |
| 5-2 | 복제 | "A" 우클릭 → "복제" | 리스트 순서: "A", "A 복사본", "B2", "C". 복사본의 경로/명령어는 원본과 동일, `id` 는 신규(=다른 UUID) |
| 5-3 | 위로 | "C" 우클릭 → "위로" | "A", "A 복사본", "C", "B2" |
| 5-4 | 위로 (최상단 no-op) | 맨 위 "A" 우클릭 → "위로" | 순서 변화 없음 |
| 5-5 | 아래로 | "A" 우클릭 → "아래로" | "A 복사본", "A", "C", "B2" |
| 5-6 | 아래로 (최하단 no-op) | 맨 아래 항목 우클릭 → "아래로" | 순서 변화 없음 |
| 5-7 | 삭제 (확인 다이얼로그) | 임의 항목 우클릭 → "삭제…" | confirmationDialog: "이 항목을 삭제하시겠습니까?" "<name> 을(를) 영구적으로 제거합니다." 표시 |
| 5-8 | 삭제 취소 | 5-7 다이얼로그에서 "취소" | 리스트 변화 없음 |
| 5-9 | 삭제 실행 | 5-7 다이얼로그에서 "삭제" | 리스트 + `entries.json` 에서 해당 항목 제거. 나머지 항목의 `sortIndex` 가 0..n-1 로 재정렬 |

---

## 6. 드래그&드롭 순서 변경 (수락 기준: 드래그 가능 + 재실행 후 순서 유지)

| # | 시나리오 | 조작 | 기대 결과 |
|---|---|---|---|
| 6-1 | 드래그 이동 | 3건 이상 상태에서 첫 행을 마지막 위치로 드래그 | UI 에서 마지막에 위치 |
| 6-2 | 디스크 반영 | 6-1 직후 `cat "$HOME/Library/Application Support/PathDock/entries.json" \| jq '.[] \| {name, sortIndex}'` | 새 순서대로 `sortIndex` 가 0..n-1 부여됨 |
| 6-3 | 재실행 후 순서 유지 | `Cmd+Q` → 재실행 | 6-1 의 순서 그대로 표시 |

---

## 7. 영속화 / 디바운스 (수락 기준: applicationWillTerminate 시 즉시 flush)

| # | 시나리오 | 조작 | 기대 결과 |
|---|---|---|---|
| 7-1 | 추가 직후 Cmd+Q | 항목 추가 → **300ms 안에** Cmd+Q | 디바운스 저장이 끝나기 전에 종료해도 재실행 시 항목 유지 (AppDelegate.applicationWillTerminate 에서 saveNow flush) |
| 7-2 | JSON 파일 직접 확인 | 터미널에서 `cat "$HOME/Library/Application Support/PathDock/entries.json"` | 사람이 읽을 수 있는 prettyPrinted + sortedKeys JSON. 날짜는 ISO8601 |
| 7-3 | JSON 손상 복구 | 앱 종료 → `entries.json` 내용을 `{ broken` 로 덮어쓰기 → 앱 재실행 | 앱은 크래시 없이 빈 리스트로 시작. (로그에 `[PathDock] entries.json 로드 실패: ...` 출력) — 디스크 파일은 그대로 두지만 다음 변경 발생 시 정상 JSON 으로 덮어쓰임 |

---

## 8. 자동화 권한 거부 / 재허용 플로우 (수락 기준: 안내 메시지 표시)

| # | 시나리오 | 조작 | 기대 결과 |
|---|---|---|---|
| 8-1 | 처음부터 거부 | 2-1 시스템 다이얼로그에서 "허용 안 함" 선택 | "터미널 실행에 실패했습니다." Alert + 자동화 안내 메시지 |
| 8-2 | 시스템 설정에서 재허용 | 시스템 설정 → 개인 정보 보호 및 보안 → 자동화 → PathDock → Terminal 체크 | 다시 더블클릭하면 정상 실행 (앱 재시작 불필요) |
| 8-3 | 시스템 설정에서 다시 거부 | 8-2 후 체크 해제 → 더블클릭 | 8-1 과 동일한 안내 메시지 |

---

## 9. 빈 상태 ↔ 리스트 상태 전이

| # | 시나리오 | 조작 | 기대 결과 |
|---|---|---|---|
| 9-1 | 리스트 → 빈 상태 | 모든 항목을 삭제 | "등록된 경로가 없습니다" 빈 상태 화면이 다시 표시 |
| 9-2 | 빈 상태 → 리스트 | 9-1 에서 다시 `+` 로 1건 추가 | 빈 상태가 사라지고 리스트가 표시 |

---

## 부록 A. 단위 회귀 (자동)

비공식 standalone 스크립트로 핵심 순수 로직을 회귀 검증한다.
Xcode 테스트 타겟은 추가하지 않았다 — 그 이유와 trade-off 는 README/보고서 참조.

```bash
cd path/to/9_TerminalLauncher
swift Tests/run_unit_tests.swift
# 기대 출력: ✅ passed: 119 / ❌ failed: 0
```

검증 대상:

- `TerminalLauncher.shellEscapeSingleQuoted` — 작은따옴표, 공백, 다중 따옴표, 빈 문자열
- `TerminalLauncher.buildShellCommand` — cd만 / cd+1줄 / cd+다중줄 / 빈줄·공백줄 trim / 모두 공백 / 따옴표·공백 경로
- `TerminalLauncher.escapeForAppleScriptDoubleQuoted` — `\` / `"` / 동시 / shell escape 와의 round-trip
- `EntryStore.add` / `update` / `delete(id:)` / `delete(ids:)` / `move(from:to:)` / `moveUp` / `moveDown` / `duplicate` — 모든 변경 후 `sortIndex` 가 0..n-1 로 재정렬되는지

> 주의: standalone 스크립트는 SwiftUI 익스텐션(`Array.move(fromOffsets:toOffset:)`)에 의존할 수 없어
> 동일 시맨틱을 직접 구현했다. 실제 PathDock 의 `EntryStore.move` 는 SwiftUI 익스텐션을 호출하므로,
> SwiftUI 동작이 바뀌면 standalone 결과와 실 동작이 갈릴 가능성이 0이 아니다 — 그래서 6번(드래그)
> 수동 검증을 함께 둔다.

---

## 부록 B. 미커버 항목 / 환경 의존

- **NSAppleScript 실제 실행 결과** — 단위 테스트로는 권한 다이얼로그를 강제 발생시킬 수 없으므로
  2번/3번/8번 시나리오의 권한·새 창 확인은 항상 수동.
- **NSOpenPanel** 다이얼로그 — UI 테스트 없이는 자동화 불가. 1-3 수동.
- **드래그&드롭** 의 실제 동작 — `Array.move(fromOffsets:toOffset:)` 의 시맨틱은 단위 테스트로 회귀
  검증되지만, 실제 SwiftUI List 의 `.onMove` 가 정확한 from/to 를 전달하는지는 수동(6번).
- **iTerm2 옵션** — 현재 구현은 Terminal.app 만 지원. 시트/설정 UI 가 없으므로 해당 분기 테스트는 N/A.

---

## 10. 첫 실행 다이얼로그 / 잠금 / 비밀번호 초기화 (v2)

매 시나리오 시작 전에 다음 두 가지를 모두 정리해야 깨끗한 첫 실행 상태가 된다.
```bash
rm -rf "$HOME/Library/Application Support/PathDock"
# Keychain 항목 제거 (앱이 만든 generic password)
security delete-generic-password -s com.wannypark.pathdock.masterkey -a default 2>/dev/null || true
```

| # | 시나리오 | 조작 | 기대 결과 |
|---|---|---|---|
| 10-1 | 첫 실행 다이얼로그 노출 | 위 정리 후 앱 실행 | "명령어 / 첨부파일 암호화" 화면 + 암호 입력 / 재입력 필드 + [암호화 활성화] / [암호화하지 않기] 버튼 + "암호 분실 시 데이터 복구 불가" 경고 |
| 10-2 | 암호화하지 않기 | 10-1 화면에서 [암호화하지 않기] | 메인 화면 진입. `security.plist` 의 mode 가 `plain`. Keychain 항목 미생성. `entries.json` 사용 |
| 10-3 | 암호화 활성화 — 비번 일치 | 정리 후 앱 실행 → "p@ss1234" 두 칸 동일 입력 → [암호화 활성화] | "암호 키 생성 중…" 진행표시 → 메인 화면 진입. `security.plist` mode=encrypted, `entries.enc` 가 저장 사용됨, Keychain 항목 생성 (`security find-generic-password -s com.wannypark.pathdock.masterkey -a default`) |
| 10-4 | 암호 불일치 | 10-1 화면에서 두 칸을 다르게 입력 | [암호화 활성화] 버튼 비활성 또는 알럿. 진행 불가 |
| 10-5 | 자동 잠금 해제 | 10-3 상태에서 Cmd+Q → 재실행 | UnlockView 없이 바로 메인 진입 (Keychain 자동 사용) |
| 10-6 | Keychain 삭제 후 잠금 화면 | 10-3 상태에서 `security delete-generic-password -s com.wannypark.pathdock.masterkey -a default` 실행 → 앱 재실행 | UnlockView 노출 |
| 10-7 | 올바른 비번 입력 → 진입 | 10-6 에서 "p@ss1234" 입력 → [잠금 해제] | 메인 화면 진입 + Keychain 항목 재생성 |
| 10-8 | 잘못된 비번 | 10-6 에서 "wrong" 입력 | "잠금 해제 실패" 알럿. 필드 초기화. 시도 무제한 |
| 10-9 | 비밀번호 초기화 | 메인 → ⌘, → 설정 → [비밀번호 초기화…] | "모든 데이터가 삭제됩니다" 알럿 → 진행 시 entries/attachments/decrypted/security.plist + Keychain 항목 폐기 → 첫 실행 다이얼로그로 복귀 |

---

## 11. 첨부 (v2)

| # | 시나리오 | 조작 | 기대 결과 |
|---|---|---|---|
| 11-1 | 명령어 칸에 파일 드롭 | 추가 시트 → 명령어 칸에 `open ` 입력 후 Finder에서 텍스트 파일 드래그 → 칸에 놓기 | 커서 위치에 `{{att:<uuid>}}` 토큰 삽입, 시트 하단 첨부 목록에 원본 이름 + 크기 + 아이콘 + [제거] 버튼 표시 |
| 11-2 | 10MB 초과 파일 | 11-1 흐름에서 10MB 초과 파일 드롭 | 알럿 "10MB 를 초과합니다" → 토큰 삽입 안 됨, 디스크 저장도 안 됨 |
| 11-3 | 0 바이트 / 정확히 10MB 경계 | 10,485,760 byte 파일 드롭 | 통과 (경계 포함 허용) |
| 11-4 | 저장 후 실행 → 평문 치환 | 11-1 항목 더블클릭 | Terminal 새 창에서 `open '/Users/.../Application Support/PathDock/decrypted/<run-uuid>/<원본이름>'` 가 실행되어 파일이 열림 |
| 11-5 | 첨부 제거 시 디스크 정리 | 시트의 [제거] 버튼 → 저장 | `attachments/<uuid>` 파일 삭제됨. 명령어 본문의 토큰도 자동 제거 |
| 11-6 | 항목 삭제 시 첨부 cleanup | 첨부가 있는 항목을 삭제 | `attachments/<uuid>` 도 같이 사라짐 |
| 11-7 | dangling 토큰 실행 거부 | JSON 직접 편집으로 본문에 `{{att:UNKNOWN-UUID}}` 만들고 더블클릭 | "유효하지 않은 첨부 토큰입니다" 알럿. Terminal 새 창 생성 안 함 |
| 11-8 | 평문 디렉토리 cleanup | 11-4 실행 후 Cmd+Q → 재실행 | `decrypted/` 안의 이전 run 디렉토리들이 모두 사라져 있어야 함 |
| 11-9 | encrypted 모드에서 디스크 평문 노출 X | encrypted 모드에서 11-1 진행 후 `attachments/<uuid>` 를 `cat` | 평문이 아닌 임의 바이너리 (nonce|ct|tag) 가 보임 |

---

## 12. Export / Import (v2)

| # | 시나리오 | 조작 | 기대 결과 |
|---|---|---|---|
| 12-1 | Export 비번 시트 | 메인 → ⌘, → [Export…] → NSSavePanel 으로 `~/Desktop/test.pathdock` 지정 → 비번 시트에 "exportPW" 두 번 입력 | 단일 `.pathdock` 파일 생성. `xxd test.pathdock | head` 첫 8바이트가 "PDOCKv1\0" 확인 |
| 12-2 | Import 정상 흐름 | 메인 → 비번 초기화 → 다시 첫 실행 진행 → 메인 → [Import…] → 12-1 파일 선택 → "exportPW" 입력 | entries 와 첨부가 기존 리스트에 **append 병합**. 새 UUID 로 재할당되어 충돌 없음 |
| 12-3 | Import 잘못된 비번 | 12-2 에서 "wrong" 입력 | "Import 실패" 알럿. 데이터 변경 없음 |
| 12-4 | Import — 손상 파일 | 임의의 텍스트 파일을 .pathdock 으로 선택 | magic 검증 실패 알럿 |
| 12-5 | Import 후 첨부 실행 | 12-2 직후 import 된 항목 더블클릭 | 평문 풀기 + 셸 escape + 명령 실행 정상 |

---

## 13. 원격연결 타입 — SSH / VNC

### 13.1 추가 시트의 타입 Picker

| # | 시나리오 | 조작 | 기대 결과 |
|---|---|---|---|
| 13-1 | Picker 노출 | `+` → 시트 상단에 segmented Picker `명령어 / SSH / VNC` 노출 | 디폴트는 명령어, 선택 시 그 아래 필드가 즉시 교체 |
| 13-2 | kind 별 동적 필드 | Picker 를 SSH 로 전환 | 경로/명령어/첨부 필드가 사라지고 호스트/포트/사용자명/인증 방식/메모가 표시 |
| 13-3 | kind 전환 시 state 보존 | SSH 에서 host 입력 → 명령어 로 전환 → 다시 SSH 로 복귀 | 이전 host 값 그대로 |

### 13.2 SSH 키파일 모드

| # | 시나리오 | 조작 | 기대 결과 |
|---|---|---|---|
| 13-4 | 키파일 첨부 | SSH 폼 → 인증 방식 "키파일" → "키파일 선택…" → `~/.ssh/id_rsa` 선택 | 첨부 시스템에 저장됨. 시트에 키파일 이름 + 크기 + [제거] 표시 |
| 13-5 | 10MB 초과 키파일 거부 | 11MB 더미 파일 선택 | 알럿 후 추가 거부 |
| 13-6 | 저장 + 실행 | host=test.host, port=22, user=ubuntu, 키 선택 → 저장 → 더블클릭 | Terminal 새 창에서 `ssh 'ubuntu@test.host' -p 22 -i '/.../<keyfile>'` 실행. 키파일이 `decrypted/<run-uuid>/<원본이름>` 에 풀려 있고 `stat -f '%Lp' <path>` 가 `600` |

### 13.3 SSH 패스워드 모드

| # | 시나리오 | 조작 | 기대 결과 |
|---|---|---|---|
| 13-7 | 패스워드 저장 | 인증 방식 "패스워드" → 패스워드 SecureField 입력 → 저장 | encrypted 모드면 entries.enc 안에 암호화. plain 모드면 entries.json 안에 평문 |
| 13-8 | 더블클릭 → 클립보드 복사 + 안내 | 13-7 항목 더블클릭 | 클립보드에 패스워드 복사 + Terminal 새 창에서 `echo '🔑 패스워드가 클립보드에 복사되었습니다. ...' && ssh 'user@host' -p 22` 실행. ssh 가 패스워드 프롬프트를 띄우면 ⌘V 로 붙여넣어 진입 |
| 13-9 | 패스워드 비어있음 | 패스워드 빈 채로 저장 → 더블클릭 | echo 줄 없이 `ssh '...'` 만 실행 (시스템 기본 키 인증 시도) |

### 13.4 VNC

| # | 시나리오 | 조작 | 기대 결과 |
|---|---|---|---|
| 13-10 | 기본 VNC 연결 | host=192.168.0.20, port=5900, user=admin, password=secret → 저장 → 더블클릭 | macOS 화면 공유 또는 등록된 vnc 핸들러가 활성화되며 `vnc://admin:secret@192.168.0.20:5900` 으로 자동 인증 시도 |
| 13-11 | 사용자명 없이 패스워드만 | user 빈 채 password=secret → 더블클릭 | `vnc://:secret@host` 형태 호출. 화면공유 처리 결과는 환경 의존 |
| 13-12 | 특수문자 escape | password=`p ss@1` → 더블클릭 | URL 합성 시 `p%20ss%401` 로 percent-encode 되어 호출 |
| 13-13 | 빈 host 저장 거부 | host 빈 채 저장 시도 | 저장 버튼 비활성 |

### 13.5 리스트 표시

| # | 시나리오 | 조작 | 기대 결과 |
|---|---|---|---|
| 13-14 | 카테고리 구분 | 명령어 1건 + SSH 1건 + VNC 1건 추가 | 각 행 좌측 아이콘이 `terminal` / `network` / `display`, 이름 옆에 `SSH`(녹색) / `VNC`(파랑) 뱃지 표시 (명령어는 뱃지 생략), 부제는 명령어는 경로/명령요약, 원격은 `user@host:port` |

### 13.6 backward compat

| # | 시나리오 | 조작 | 기대 결과 |
|---|---|---|---|
| 13-15 | v2 JSON 호환 | `kind` 필드가 없는 기존 v2 entries.json 으로 앱 실행 | 모두 `kind=.command` 로 디코드되어 정상 표시 |

---

## 14. ssh config 가져오기 (SSH 타입)

> 사전: `~/.ssh/config` 가 존재해야 한다. 없으면 다음으로 임시 작성:
> ```
> Host devbox
>     HostName 192.168.0.10
>     User ubuntu
>     Port 2222
>     IdentityFile ~/.ssh/id_rsa
>
> Host *
>     ServerAliveInterval 30
> ```

| # | 시나리오 | 조작 | 기대 결과 |
|---|---|---|---|
| 14-1 | 메뉴 노출 | `+` → 타입 Picker 를 SSH 로 전환 | "ssh config" 섹션의 "ssh config 에서 가져오기" 메뉴 버튼 활성. Host 가 0건이면 안내 라벨 "~/.ssh/config 에 등록된 Host 가 없습니다." |
| 14-2 | 메뉴 항목 표시 | 메뉴 펼치기 | `devbox — ubuntu@192.168.0.10:2222` 표기. 와일드카드 `*` 항목은 보이지 않음 |
| 14-3 | 선택 시 폼 자동 채움 | `devbox` 선택 | host=`192.168.0.10`, 포트=`2222`, 사용자명=`ubuntu`, 인증 방식=키파일, IdentityFile 이 첨부 시스템에 자동 import 되어 키파일 행에 `id_rsa` 표시 |
| 14-4 | IdentityFile 없는 Host | Host 블록에 IdentityFile 없는 항목 추가 후 메뉴 선택 | host/port/user 만 채워지고 인증 방식=패스워드 로 전환 |
| 14-5 | IdentityFile 경로 부재 | Host 의 IdentityFile 을 존재하지 않는 경로(`~/.ssh/missing`)로 두고 선택 | 알럿 "IdentityFile 경로의 파일을 찾을 수 없습니다…" + 인증 방식=키파일 로 전환되지만 keyAttachmentId 는 비어 있음. 사용자가 "키파일 선택…"으로 직접 지정 가능 |
| 14-6 | 10MB 초과 IdentityFile | 11MB 더미 파일을 IdentityFile 로 지정 후 선택 | 알럿 "파일이 너무 큽니다…" + 첨부 import 거부 |
| 14-7 | 가져오기 후 자유 편집 | 14-3 직후 host/port/user 를 임의 값으로 수정 → 저장 | 수정값 그대로 저장됨 |
| 14-8 | 빈 ssh config | `~/.ssh/config` 를 삭제하거나 빈 파일로 두고 시트 열기 | 메뉴 자리에 안내 라벨 표시, 메뉴 클릭 불가 |

---

## 15. SSH "추가 옵션" 필드 (HostKeyAlgorithms 등)

> 사전: `~/.ssh/config` 에 다음 Host 를 추가.
> ```
> Host legacy
>     HostName 14.63.169.122
>     Port 30022
>     User admin
>     HostKeyAlgorithms +ssh-rsa,ssh-dss
>     PubkeyAcceptedAlgorithms +ssh-rsa
> ```

| # | 시나리오 | 조작 | 기대 결과 |
|---|---|---|---|
| 15-1 | 가져오기 시 자동 채움 | `+` → SSH → 우측 "ssh config" 버튼 → `legacy` 선택 | 추가 옵션 텍스트 영역에 두 줄: `HostKeyAlgorithms +ssh-rsa,ssh-dss` / `PubkeyAcceptedAlgorithms +ssh-rsa` |
| 15-2 | 사용자 직접 입력 | "추가 옵션" 영역에 직접 `ServerAliveInterval 30` 입력 → 저장 → 더블클릭 | Terminal 새 창에서 `ssh '...' -p ... -o'ServerAliveInterval=30'` 가 실행 |
| 15-3 | 다중 옵션 합성 | 옵션 3줄 입력 후 더블클릭 | ssh 명령에 `-o'K1=V1' -o'K2=V2' -o'K3=V3'` 3개가 순서대로 추가 |
| 15-4 | 빈 줄 / 키만 있는 줄 무시 | 옵션 영역에 `\n\n  ` 및 `Foo` (값 없음) 입력 → 저장 | ssh 명령에 잘못된 -o 인자가 추가되지 않음 |
| 15-5 | 작은따옴표 escape | 옵션 `RemoteCommand echo 'hi'` 입력 → 더블클릭 | ssh 명령에 `-o'RemoteCommand=echo '\''hi'\'''` 가 안전하게 escape 되어 들어감 |
| 15-6 | Key=Value 형식도 허용 | `ServerAliveInterval=30` 입력 → 더블클릭 | `-o'ServerAliveInterval=30'` 동일 결과 |
| 15-7 | 옵션 적용 결과 (legacy 호스트) | 15-1 항목 저장 → 더블클릭 | "no matching host key type" 에러 없이 비번/키파일 인증 단계로 진행 |

---

## 16. 터미널 백엔드 (Terminal / iTerm2) 와 세션 추적

> 사전: 일부 시나리오는 iTerm2 설치/미설치 두 환경에서 모두 검증해야 한다.

### 16.1 첫 실행 다이얼로그

| # | 시나리오 | 조작 | 기대 결과 |
|---|---|---|---|
| 16-1 | 백엔드 Picker 노출 | 모든 데이터 초기화 후 앱 실행 | 패스워드 영역 아래에 "터미널 선택" + segmented Picker(Terminal / iTerm2) |
| 16-2 | iTerm2 선택 + 미설치 + "암호화 활성화" | iTerm2 가 설치되지 않은 환경에서 Picker iTerm2 선택 후 버튼 클릭 | 알럿 "iTerm2 가 설치되어 있지 않습니다." + [확인] / [설치하기] 버튼. 알럿 닫아도 첫 실행 화면 그대로 (진행 안 함) |
| 16-3 | [설치하기] 버튼 동작 | 16-2 알럿의 [설치하기] | 기본 브라우저로 `https://iterm2.com/` 이동 |
| 16-4 | iTerm2 선택 + 설치됨 | iTerm2 가 설치된 환경에서 Picker iTerm2 선택 후 [암호화하지 않기] | preferences.json 의 `terminalBackend = iTerm2` 로 저장 + 메인 진입 |
| 16-5 | Terminal 기본값 | Picker 기본 선택 확인 | 별도 조작 없이 Terminal 이 선택되어 있음 |

### 16.2 Settings 에서 백엔드 변경

| # | 시나리오 | 조작 | 기대 결과 |
|---|---|---|---|
| 16-6 | Settings 의 터미널 섹션 | ⌘, → 설정 → 터미널 섹션 노출 | segmented Picker + (미설치 시 [설치하기] 링크) |
| 16-7 | iTerm2 → Terminal | 백엔드 변경 | preferences.json 갱신 + 기존 세션 매핑 모두 폐기 (sessions.json 비워짐) + 리스트 인디케이터 사라짐 |
| 16-8 | Terminal → iTerm2 (미설치) | Picker 변경 | 변경 취소 + 알럿 (설치하기 버튼 동일) |
| 16-9 | iTerm2 자동 입력 토글 | 설정 → iTerm2 → "SSH 패스워드 자동 입력" 토글 | preferences.json `itermAutoTypePassword` 갱신 |

### 16.3 iTerm2 세션 추적

> 사전: 백엔드 iTerm2, SSH 항목 1건 등록 (host=test.host, user=admin, password=secret)

| # | 시나리오 | 조작 | 기대 결과 |
|---|---|---|---|
| 16-10 | 첫 더블클릭 | 항목 더블클릭 | iTerm2 활성화 + 새 창 생성, ssh 명령 실행. 1~2초 후 리스트 행에 **● 실행 중** 표시 |
| 16-11 | 자동 패스워드 입력 | 16-10 직후 ssh 패스워드 프롬프트 등장 후 약 2초 | iTerm2 가 패스워드를 자동으로 입력. (자동 입력 OFF 시는 클립보드 복사 + echo 안내) |
| 16-12 | 재 더블클릭 (세션 살아있음) | 같은 항목 다시 더블클릭 | 새 창 만들지 않고 기존 세션을 앞으로 가져옴 |
| 16-13 | iTerm2 에서 창 닫기 → 더블클릭 | iTerm2 에서 그 세션 닫고 PathDock 에서 더블클릭 | 새 세션이 생성 (인디케이터도 새 세션 기준으로 갱신) |
| 16-14 | "새 세션으로 실행" | 항목 우클릭 → "새 세션으로 실행" | 살아있는 세션과 별개로 새 창이 추가 생성. SessionStore 매핑은 새 세션으로 갱신 (이전 창은 PathDock 추적 밖) |
| 16-15 | "세션 종료" | 항목 우클릭 → "세션 종료" | iTerm2 의 해당 세션 닫힘 + 인디케이터 사라짐. 메뉴 항목도 다음 우클릭부터 사라짐 |
| 16-16 | 폴링 정지 (윈도우 비활성) | PathDock 윈도우를 백그라운드로 보낸 뒤 iTerm2 세션 닫기 → 다시 PathDock 활성화 | 활성화 후 다음 폴링(최대 2초)에 인디케이터가 사라짐. 백그라운드 동안엔 폴링 없음 |
| 16-17 | PathDock 재시작 후 매핑 검증 | iTerm2 세션 살아있는 상태에서 PathDock Cmd+Q → 재실행 | sessions.json 의 매핑이 검증되어 살아있는 건 인디케이터 유지, iTerm2 가 재시작됐다면 폐기 |

### 16.4 backward compat

| # | 시나리오 | 조작 | 기대 결과 |
|---|---|---|---|
| 16-18 | preferences.json 부재 | 새 설치 또는 reset 후 첫 실행 | 기본값 `terminalBackend=Terminal`, `itermAutoTypePassword=true` 로 시작 |
| 16-19 | sessions.json 부재 | 첫 실행 또는 잘못 삭제 | 빈 매핑으로 시작. 첫 더블클릭부터 정상 동작 |
