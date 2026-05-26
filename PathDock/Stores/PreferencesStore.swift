//
//  PreferencesStore.swift
//  PathDock
//
//  Preferences 의 로드/저장. 변경 즉시 디스크에 평문 JSON 으로 직렬화한다.
//  디바운스는 두지 않는다 (변경 빈도가 매우 낮음).
//

import Foundation
import SwiftUI

@MainActor
final class PreferencesStore: ObservableObject {
    /// 현재 메모리 상의 환경설정
    @Published var prefs: Preferences {
        didSet {
            // SwiftUI Binding 으로 변경되는 모든 경로를 커버하기 위해 즉시 저장
            save()
        }
    }

    /// 저장 파일 경로 (~/Library/Application Support/PathDock/preferences.json)
    let fileURL: URL

    /// 외부 트리거(직접 prefs 갱신 + save() 호출) 시 didSet 재진입 방지용
    private var suppressSave = false

    init(rootDir: URL) {
        self.fileURL = rootDir.appendingPathComponent("preferences.json")
        // 초기값을 일단 default 로 세팅한 뒤, 디스크에서 로드해 덮어쓴다.
        self.prefs = .default
        load()
    }

    /// 디스크에서 prefs 를 읽어 메모리에 반영. 파일이 없거나 디코드 실패면 기본값.
    func load() {
        let fm = FileManager.default
        guard fm.fileExists(atPath: fileURL.path) else {
            // 파일 없음 → 기본값 유지
            return
        }
        do {
            let data = try Data(contentsOf: fileURL)
            let decoded = try JSONDecoder().decode(Preferences.self, from: data)
            // didSet save() 가 다시 호출되지 않도록 가드
            suppressSave = true
            self.prefs = decoded
            suppressSave = false
        } catch {
            NSLog("[PathDock] preferences.json 로드 실패: %@", String(describing: error))
        }
    }

    /// 현재 메모리 prefs 를 디스크에 즉시 저장. didSet 에서 자동 호출되지만 외부에서도 호출 가능.
    func save() {
        if suppressSave { return }
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(prefs)
            try data.write(to: fileURL, options: [.atomic])
        } catch {
            NSLog("[PathDock] preferences.json 저장 실패: %@", String(describing: error))
        }
    }
}
