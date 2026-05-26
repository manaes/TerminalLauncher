//
//  RemoteLauncher.swift
//  PathDock
//
//  Terminal.app 이 아닌 시스템 핸들러(NSWorkspace.open(URL))를 통해
//  처리되는 원격 프로토콜(현재 VNC)을 실행하는 서비스.
//

import Foundation
import AppKit

/// VNC 등 OS 의 URL 핸들러로 위임해 실행하는 원격 항목 런처.
enum RemoteLauncher {

    /// VNC 항목 한 건을 macOS 의 화면 공유 클라이언트(또는 등록된 vnc:// 핸들러)로 연다.
    /// URL 형식: `vnc://[username[:password]@]host[:port]`
    /// username/password 는 percent-encoding 으로 안전하게 escape 한다.
    @MainActor
    static func launchVNC(_ entry: PathEntry) throws {
        guard entry.kind == .remoteVNC else {
            throw LaunchError.invalidRemoteConfig("VNC 타입이 아닙니다. (kind=\(entry.kind.rawValue))")
        }

        // 1) host 검증
        let host = (entry.host ?? "").trimmingCharacters(in: .whitespaces)
        guard !host.isEmpty else {
            throw LaunchError.invalidRemoteConfig("호스트(주소)가 비어 있습니다.")
        }

        // 2) URL 합성 — userInfo, host, port 각 부분을 percent-encode
        // RFC 3986 의 user-info 에서 허용되지 않는 문자(@, :, /, ?, # 등)를 escape.
        // URLUserAllowed 는 ':' 를 허용하므로, 사용자명에 ':' 가 들어가는 경우를 분리하기 위해
        // 별도 user/password set 을 명시적으로 좁혀 사용한다.
        var userInfo = ""
        let username = (entry.username ?? "").trimmingCharacters(in: .whitespaces)
        let password = entry.password ?? ""
        // user-info 에서 안전한 문자 집합 (':' 를 빼고 percent-encoding 강제)
        let safeUserInfo = CharacterSet(charactersIn:
            "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        if !username.isEmpty {
            let u = username.addingPercentEncoding(withAllowedCharacters: safeUserInfo) ?? username
            if !password.isEmpty {
                let p = password.addingPercentEncoding(withAllowedCharacters: safeUserInfo) ?? password
                userInfo = "\(u):\(p)@"
            } else {
                userInfo = "\(u)@"
            }
        } else if !password.isEmpty {
            // 사용자명이 없는데 패스워드만 있는 경우 — vnc:// URL 표준상 모호하므로
            // ":<password>@" 로 인코딩한다(빈 사용자명).
            let p = password.addingPercentEncoding(withAllowedCharacters: safeUserInfo) ?? password
            userInfo = ":\(p)@"
        }

        let hostEncoded = host.addingPercentEncoding(withAllowedCharacters: .urlHostAllowed) ?? host
        var urlString = "vnc://\(userInfo)\(hostEncoded)"
        if let port = entry.port {
            urlString += ":\(port)"
        }

        guard let url = URL(string: urlString) else {
            throw LaunchError.invalidRemoteConfig("VNC URL 합성 실패: \(urlString)")
        }

        // 3) NSWorkspace 로 열기
        let ok = NSWorkspace.shared.open(url)
        if !ok {
            throw LaunchError.vncOpenFailed("등록된 vnc:// 핸들러가 열리지 않았습니다.\nURL: \(url.absoluteString)")
        }
    }
}
