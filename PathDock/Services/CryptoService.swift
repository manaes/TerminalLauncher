//
//  CryptoService.swift
//  PathDock
//
//  AES-GCM-256 / PBKDF2-SHA256 / 메모리 잠금(LockedData) 캡슐화.
//  - AES-GCM: Apple CryptoKit
//  - PBKDF2: CommonCrypto (CryptoKit 미제공)
//

import Foundation
import CryptoKit
import CommonCrypto

/// 암복호 단계에서 발생할 수 있는 오류
enum CryptoError: LocalizedError {
    /// PBKDF2 호출 실패
    case kdfFailed
    /// 입력 데이터 포맷이 잘못됨 (길이 부족 등)
    case invalidPayload
    /// GCM 복호화 실패 (잘못된 키 / 손상된 데이터)
    case decryptionFailed
    /// 키 길이가 32 바이트가 아님
    case invalidKeyLength

    var errorDescription: String? {
        switch self {
        case .kdfFailed: return "키 유도(PBKDF2)에 실패했습니다."
        case .invalidPayload: return "암호화 데이터 포맷이 올바르지 않습니다."
        case .decryptionFailed: return "복호화에 실패했습니다. (잘못된 비밀번호이거나 데이터가 손상되었습니다.)"
        case .invalidKeyLength: return "키 길이가 32바이트(AES-256)가 아닙니다."
        }
    }
}

/// 32 바이트 AES-256 키를 mlock 으로 잠궈 보관하는 래퍼.
/// 해제 시 0-fill 후 munlock 한다. 완전한 보장은 OS 스왑 정책에 의존한다.
final class LockedData {
    /// 잠궈둔 바이트 수
    let length: Int
    /// 실제 메모리 포인터
    private let buffer: UnsafeMutableRawPointer

    /// Data 의 내용을 잠긴 메모리에 복사한 뒤 입력 Data 를 0-fill 한다.
    init(copying source: inout Data) {
        let len = source.count
        self.length = len
        let ptr = UnsafeMutableRawPointer.allocate(byteCount: len, alignment: 1)
        // mlock 으로 스왑 차단 시도 (실패해도 동작은 계속)
        _ = mlock(ptr, len)
        source.withUnsafeBytes { src in
            if let base = src.baseAddress {
                memcpy(ptr, base, len)
            }
        }
        self.buffer = ptr
        // 입력 Data 평문도 즉시 0-fill 시도
        source.resetBytes(in: 0..<len)
    }

    /// raw 바이트로 직접 잠금 (PBKDF2 결과처럼 한번에 들어오는 경우)
    init(takingOwnershipOf source: UnsafeMutableRawPointer, length: Int) {
        self.length = length
        _ = mlock(source, length)
        self.buffer = source
    }

    deinit {
        // 0-fill 후 munlock + 해제
        memset_s(buffer, length, 0, length)
        _ = munlock(buffer, length)
        buffer.deallocate()
    }

    /// 잠긴 키 바이트를 잠깐 들여다본다. block 안에서만 사용해야 함.
    func withBytes<R>(_ block: (UnsafeRawBufferPointer) throws -> R) rethrows -> R {
        let bp = UnsafeRawBufferPointer(start: buffer, count: length)
        return try block(bp)
    }

    /// CryptoKit SymmetricKey 로 잠시 변환해 사용한다. 사용 직후 컨텍스트가 끝나면 ARC 가 해제.
    func withSymmetricKey<R>(_ block: (SymmetricKey) throws -> R) rethrows -> R {
        try withBytes { bp in
            let key = SymmetricKey(data: Data(bytes: bp.baseAddress!, count: bp.count))
            return try block(key)
        }
    }
}

/// 암복호 헬퍼들. instance 가 필요 없는 순수 함수 집합.
enum CryptoService {

    // MARK: - 랜덤

    /// `SecRandomCopyBytes` 로 안전한 랜덤 바이트 N개 생성
    static func randomBytes(_ count: Int) -> Data {
        var data = Data(count: count)
        let result = data.withUnsafeMutableBytes { raw -> Int32 in
            guard let base = raw.baseAddress else { return errSecParam }
            return SecRandomCopyBytes(kSecRandomDefault, count, base)
        }
        precondition(result == errSecSuccess, "SecRandomCopyBytes 실패")
        return data
    }

    // MARK: - PBKDF2

    /// PBKDF2-SHA256 으로 32바이트 키를 유도하여 LockedData 로 감싼다.
    /// password 와 salt 평문은 함수가 책임지지 않는다 (호출자가 zero-fill 시도).
    static func deriveKey(password: String, salt: Data, iterations: Int) throws -> LockedData {
        let outLen = 32
        // mlock 가능한 raw 버퍼에 곧바로 PBKDF2 결과를 받는다.
        let outPtr = UnsafeMutableRawPointer.allocate(byteCount: outLen, alignment: 1)
        let typed = outPtr.bindMemory(to: UInt8.self, capacity: outLen)

        let status = password.withCString { passPtr -> Int32 in
            // PBKDF2 패스워드 바이트 길이 = strlen
            let passLen = strlen(passPtr)
            return salt.withUnsafeBytes { saltRaw -> Int32 in
                guard let saltBase = saltRaw.bindMemory(to: UInt8.self).baseAddress else {
                    return Int32(kCCParamError)
                }
                return CCKeyDerivationPBKDF(
                    CCPBKDFAlgorithm(kCCPBKDF2),
                    passPtr,
                    passLen,
                    saltBase,
                    salt.count,
                    CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256),
                    UInt32(iterations),
                    typed,
                    outLen
                )
            }
        }

        guard status == kCCSuccess else {
            // 실패 시 즉시 0-fill 후 해제
            memset_s(outPtr, outLen, 0, outLen)
            outPtr.deallocate()
            throw CryptoError.kdfFailed
        }
        // 성공: outPtr 소유권을 LockedData 로 이관 (mlock 은 LockedData 가 처리)
        return LockedData(takingOwnershipOf: outPtr, length: outLen)
    }

    // MARK: - AES-GCM

    /// 평문을 키로 AES-GCM 암호화하여 `nonce(12) || ciphertext || tag(16)` 단일 Data 로 반환.
    static func encryptGCM(plaintext: Data, key: LockedData) throws -> Data {
        guard key.length == 32 else { throw CryptoError.invalidKeyLength }
        let sealed = try key.withSymmetricKey { sk -> AES.GCM.SealedBox in
            return try AES.GCM.seal(plaintext, using: sk)
        }
        // CryptoKit 의 combined 은 nonce || ct || tag 와 동일한 12/-/16 레이아웃이지만
        // 명시성을 위해 직접 합친다.
        var out = Data()
        out.append(sealed.nonce.withUnsafeBytes { Data($0) })
        out.append(sealed.ciphertext)
        out.append(sealed.tag)
        return out
    }

    /// `nonce(12) || ciphertext || tag(16)` 포맷을 키로 AES-GCM 복호화하여 평문 반환.
    /// 잘못된 키 / 손상된 데이터면 `decryptionFailed` throw.
    static func decryptGCM(payload: Data, key: LockedData) throws -> Data {
        guard key.length == 32 else { throw CryptoError.invalidKeyLength }
        guard payload.count >= 12 + 16 else { throw CryptoError.invalidPayload }
        let nonceData = payload.prefix(12)
        let tagData = payload.suffix(16)
        let ct = payload.dropFirst(12).dropLast(16)
        do {
            let nonce = try AES.GCM.Nonce(data: nonceData)
            let box = try AES.GCM.SealedBox(nonce: nonce, ciphertext: ct, tag: tagData)
            return try key.withSymmetricKey { sk in
                try AES.GCM.open(box, using: sk)
            }
        } catch {
            throw CryptoError.decryptionFailed
        }
    }

    /// 분리된 nonce/ct/tag 가 필요한 경우(verifier 저장)에 사용하는 저수준 변형.
    static func encryptGCMSplit(plaintext: Data, key: LockedData) throws -> (nonce: Data, ciphertext: Data, tag: Data) {
        guard key.length == 32 else { throw CryptoError.invalidKeyLength }
        let sealed = try key.withSymmetricKey { sk -> AES.GCM.SealedBox in
            try AES.GCM.seal(plaintext, using: sk)
        }
        let nonceData = sealed.nonce.withUnsafeBytes { Data($0) }
        return (nonceData, sealed.ciphertext, sealed.tag)
    }

    /// 분리된 nonce/ct/tag 로부터 복호화
    static func decryptGCMSplit(nonce: Data, ciphertext: Data, tag: Data, key: LockedData) throws -> Data {
        guard key.length == 32 else { throw CryptoError.invalidKeyLength }
        do {
            let n = try AES.GCM.Nonce(data: nonce)
            let box = try AES.GCM.SealedBox(nonce: n, ciphertext: ciphertext, tag: tag)
            return try key.withSymmetricKey { sk in
                try AES.GCM.open(box, using: sk)
            }
        } catch {
            throw CryptoError.decryptionFailed
        }
    }
}
