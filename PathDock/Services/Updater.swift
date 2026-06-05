//
//  Updater.swift
//  PathDock
//
//  Sparkle 자동 업데이트 통합.
//  - Info.plist 의 SUFeedURL(appcast.xml) / SUPublicEDKey(EdDSA 공개키) 로 동작한다.
//  - 앱 메뉴(앱 이름 → "업데이트 확인…")에서 수동 확인, SUEnableAutomaticChecks=YES 로 자동 확인.
//

import Combine
import Sparkle
import SwiftUI

/// Sparkle 업데이트 컨트롤러를 앱 생명주기 동안 보유한다.
/// `@StateObject` 로 App 에 하나만 두어 백그라운드 자동 확인 스케줄이 살아있게 한다.
final class UpdaterViewModel: ObservableObject {
    let controller: SPUStandardUpdaterController

    init() {
        // startingUpdater: true → Info.plist 설정으로 업데이터를 즉시 시작한다.
        // 별도 delegate 가 필요 없으면 nil 로 둔다(표준 사용자 UI 사용).
        controller = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
    }
}

/// 앱 메뉴에 들어가는 "업데이트 확인…" 버튼.
/// 업데이터가 확인 가능한 상태일 때만 활성화된다(다운로드/설치 중 비활성).
struct CheckForUpdatesView: View {
    @ObservedObject private var checkModel: CheckForUpdatesViewModel
    private let updater: SPUUpdater

    init(updater: SPUUpdater) {
        self.updater = updater
        self.checkModel = CheckForUpdatesViewModel(updater: updater)
    }

    var body: some View {
        Button("업데이트 확인…") {
            updater.checkForUpdates()
        }
        .disabled(!checkModel.canCheckForUpdates)
    }
}

/// `SPUUpdater.canCheckForUpdates` 를 관찰해 메뉴 항목 활성/비활성을 SwiftUI 에 반영한다.
private final class CheckForUpdatesViewModel: ObservableObject {
    @Published var canCheckForUpdates = false

    init(updater: SPUUpdater) {
        updater.publisher(for: \.canCheckForUpdates)
            .assign(to: &$canCheckForUpdates)
    }
}
