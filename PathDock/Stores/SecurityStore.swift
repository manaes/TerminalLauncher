//
//  SecurityStore.swift
//  PathDock
//
//  보안 메타데이터(security.plist) + Keychain 마스터키를 일원화 관리한다.
//  - security.plist: Application Support/PathDock/security.plist
//  - Keychain: service=com.wannypark.pathdock.masterkey, account=default
//  - KDF: PBKDF2-SHA256, 600,000 iter, 32B output, salt 16B
//  - verifier: 임의 16B 평문을 derived key 로 GCM 암호화 → ciphertext/nonce/tag 저장
//

import Foundation
import Security

/// SecurityStore 단계의 오류
enum SecurityStoreError: LocalizedError {
    /// 비밀번호 검증 실패 (verifier 복호화 실패)
    case wrongPassword
    /// security.plist 가 손상되었거나 마이그레이션 불가
    case invalidConfig

    var errorDescription: String? {
        switch self {
        case .wrongPassword: return "비밀번호가 올바르지 않습니다."
        case .invalidConfig: return "보안 설정이 손상되었습니다."
        }
    }
}

/// 보안 상태/키 관리.
/// - `currentKey()` 는 암호화 모드일 때만 LockedData 를 반환.
/// - plain 모드면 nil.
@MainActor
final class SecurityStore: ObservableObject {

    // MARK: - 정적 상수

    /// Keychain service 식별자 (번들 ID 와 무관하게 자체 네임스페이스 사용)
    static let keychainService = "com.wannypark.pathdock.masterkey"
    /// Keychain account
    static let keychainAccount = "default"
    /// PBKDF2 반복 횟수
    static let kdfIterations = 600_000

    // MARK: - 상태

    /// 현재 디스크 상의 보안 설정. 첫 실행 시 nil.
    @Published private(set) var config: SecurityConfig?
    /// 현재 메모리에 보관 중인 derived key (encrypted 모드 + 잠금해제됨일 때만 비-nil)
    private(set) var derivedKey: LockedData?

    // MARK: - 경로

    /// 앱 데이터 루트 (~/Library/Application Support/PathDock)
    let rootDir: URL
    /// security.plist
    let configURL: URL

    // MARK: - Init

    init() {
        let fm = FileManager.default
        let base = (try? fm.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )) ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        let dir = base.appendingPathComponent("PathDock", isDirectory: true)
        if !fm.fileExists(atPath: dir.path) {
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        self.rootDir = dir
        self.configURL = dir.appendingPathComponent("security.plist")
        self.config = Self.loadConfig(from: configURL)
    }

    // MARK: - security.plist IO

    /// 디스크에서 SecurityConfig 로드. 없으면 nil.
    private static func loadConfig(from url: URL) -> SecurityConfig? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        do {
            let data = try Data(contentsOf: url)
            let decoder = PropertyListDecoder()
            return try decoder.decode(SecurityConfig.self, from: data)
        } catch {
            NSLog("[PathDock] security.plist 로드 실패: %@", String(describing: error))
            return nil
        }
    }

    /// SecurityConfig 를 plist 로 저장
    private func saveConfig(_ cfg: SecurityConfig) throws {
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .xml
        let data = try encoder.encode(cfg)
        try data.write(to: configURL, options: [.atomic])
        self.config = cfg
    }

    // MARK: - 초기 설정 (첫 실행)

    /// 평문 모드로 확정. security.plist 만 생성.
    func setupPlain() throws {
        let cfg = SecurityConfig.plain()
        try saveConfig(cfg)
    }

    /// 암호화 모드로 확정. 비밀번호로 derived key 를 만들고 verifier 저장, Keychain 에 키 저장.
    /// 호출 후 `derivedKey` 가 채워진다.
    func setupEncrypted(password: String) throws {
        let salt = CryptoService.randomBytes(16)
        let key = try CryptoService.deriveKey(password: password, salt: salt, iterations: Self.kdfIterations)

        // verifier: 임의 16바이트를 derived key 로 암호화 (분리 포맷으로 저장)
        let verifierPlain = CryptoService.randomBytes(16)
        let parts = try CryptoService.encryptGCMSplit(plaintext: verifierPlain, key: key)

        let cfg = SecurityConfig(
            mode: .encrypted,
            version: 1,
            kdfIterations: Self.kdfIterations,
            salt: salt,
            verifierCiphertext: parts.ciphertext,
            verifierNonce: parts.nonce,
            verifierTag: parts.tag,
            createdAt: Date()
        )
        try saveConfig(cfg)

        // Keychain 에 derived key 저장
        try storeKeyInKeychain(key)
        self.derivedKey = key
    }

    // MARK: - 잠금 해제 흐름

    /// 앱 시작 시 자동 잠금 해제 시도. encrypted 모드에서 Keychain 에 키가 있으면 success.
    /// 반환값:
    ///  - true: derivedKey 채워짐 → ready
    ///  - false: encrypted 모드인데 Keychain 비어있음 → 잠금 화면 필요
    func tryAutoUnlock() -> Bool {
        guard let cfg = config, cfg.mode == .encrypted else { return false }
        guard let key = loadKeyFromKeychain() else { return false }
        // verifier 검증
        guard let nonce = cfg.verifierNonce,
              let ct = cfg.verifierCiphertext,
              let tag = cfg.verifierTag else {
            return false
        }
        do {
            _ = try CryptoService.decryptGCMSplit(nonce: nonce, ciphertext: ct, tag: tag, key: key)
            self.derivedKey = key
            return true
        } catch {
            // Keychain 항목이 손상되었거나 verifier 와 안 맞음 → 잠금 화면으로 유도
            return false
        }
    }

    /// 비밀번호로 잠금 해제 시도. 성공 시 derived key 를 Keychain 에 재저장한다.
    func unlock(password: String) throws {
        guard let cfg = config, cfg.mode == .encrypted,
              let salt = cfg.salt,
              let nonce = cfg.verifierNonce,
              let ct = cfg.verifierCiphertext,
              let tag = cfg.verifierTag else {
            throw SecurityStoreError.invalidConfig
        }
        let key = try CryptoService.deriveKey(password: password, salt: salt, iterations: cfg.kdfIterations)
        do {
            _ = try CryptoService.decryptGCMSplit(nonce: nonce, ciphertext: ct, tag: tag, key: key)
        } catch {
            throw SecurityStoreError.wrongPassword
        }
        try storeKeyInKeychain(key)
        self.derivedKey = key
    }

    // MARK: - Keychain CRUD

    /// derived key 32바이트를 Keychain 에 저장 (기존 항목 있으면 갱신)
    private func storeKeyInKeychain(_ key: LockedData) throws {
        let keyData = key.withBytes { Data($0) }
        let baseQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.keychainService,
            kSecAttrAccount as String: Self.keychainAccount
        ]
        // 기존 항목 삭제
        SecItemDelete(baseQuery as CFDictionary)

        var addAttrs = baseQuery
        addAttrs[kSecValueData as String] = keyData
        addAttrs[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        addAttrs[kSecAttrSynchronizable as String] = kCFBooleanFalse

        let status = SecItemAdd(addAttrs as CFDictionary, nil)
        if status != errSecSuccess {
            NSLog("[PathDock] Keychain 저장 실패 status=%d", Int(status))
        }
    }

    /// Keychain 에서 derived key 조회. 없으면 nil.
    private func loadKeyFromKeychain() -> LockedData? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.keychainService,
            kSecAttrAccount as String: Self.keychainAccount,
            kSecReturnData as String: kCFBooleanTrue!,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, var data = item as? Data, data.count == 32 else {
            return nil
        }
        return LockedData(copying: &data)
    }

    /// Keychain 에서 마스터키 항목 삭제
    private func deleteKeyFromKeychain() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.keychainService,
            kSecAttrAccount as String: Self.keychainAccount
        ]
        SecItemDelete(query as CFDictionary)
    }

    // MARK: - 전체 초기화

    /// 모든 데이터(entries/attachments/decrypted/security.plist + Keychain) 폐기.
    /// 호출 후 앱은 firstRun 상태로 되돌아간다.
    func resetAll() {
        let fm = FileManager.default

        // entries.json / entries.enc
        for name in ["entries.json", "entries.enc"] {
            let url = rootDir.appendingPathComponent(name)
            try? fm.removeItem(at: url)
        }

        // attachments/ 와 decrypted/ 디렉토리 통째로 삭제
        for sub in ["attachments", "decrypted"] {
            let url = rootDir.appendingPathComponent(sub, isDirectory: true)
            try? fm.removeItem(at: url)
        }

        // security.plist 삭제
        try? fm.removeItem(at: configURL)

        // Keychain 항목 삭제
        deleteKeyFromKeychain()

        // 메모리 상태 비움
        self.derivedKey = nil
        self.config = nil
    }
}
