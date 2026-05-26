//
//  SecurityConfig.swift
//  PathDock
//
//  보안 모드/솔트/마스터키 검증 토큰(verifier) 메타데이터.
//  Application Support/PathDock/security.plist 에 저장된다.
//

import Foundation

/// 앱의 보안 설정. 한 번 결정되면 모드 전환 불가(전체 초기화 시 재설정).
struct SecurityConfig: Codable {
    /// 평문 모드 또는 암호화 모드. 한 번 정해지면 reset 전까지 변경 불가.
    enum Mode: String, Codable { case plain, encrypted }

    /// 현재 보안 모드
    var mode: Mode
    /// security.plist 스키마 버전 (현재 1)
    var version: Int
    /// PBKDF2 반복 횟수 (현재 600,000)
    var kdfIterations: Int
    /// PBKDF2 솔트 (16 바이트). encrypted 모드에서만 존재
    var salt: Data?
    /// 마스터키 검증 토큰 ciphertext (encrypted 모드 only)
    var verifierCiphertext: Data?
    /// verifier 암호화 시 nonce (12 바이트)
    var verifierNonce: Data?
    /// verifier 암호화 시 GCM tag (16 바이트)
    var verifierTag: Data?
    /// 생성 시각
    var createdAt: Date

    /// 평문 모드 기본 인스턴스
    static func plain(now: Date = Date()) -> SecurityConfig {
        SecurityConfig(
            mode: .plain,
            version: 1,
            kdfIterations: 600_000,
            salt: nil,
            verifierCiphertext: nil,
            verifierNonce: nil,
            verifierTag: nil,
            createdAt: now
        )
    }
}
