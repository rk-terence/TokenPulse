import Foundation
import CommonCrypto
import SQLite3

enum ChromeCookieError: LocalizedError {
    case chromeNotInstalled
    case dbCopyFailed
    case dbOpenFailed(String)
    case cookieNotFound(String)
    case keychainFailed
    case keyDerivationFailed
    case decryptionFailed

    var errorDescription: String? {
        switch self {
        case .chromeNotInstalled:
            return String(localized: "Chrome cookies database not found")
        case .dbCopyFailed:
            return String(localized: "Failed to copy Chrome cookies database")
        case .dbOpenFailed(let msg):
            return String(localized: "Failed to open cookies database: \(msg)")
        case .cookieNotFound(let name):
            return String(localized: "Cookie '\(name)' not found for zenmux.ai")
        case .keychainFailed:
            return String(localized: "Failed to read Chrome Safe Storage key from Keychain")
        case .keyDerivationFailed:
            return String(localized: "PBKDF2 key derivation failed")
        case .decryptionFailed:
            return String(localized: "Cookie decryption failed")
        }
    }
}

struct ZenMuxCookies: Sendable {
    let ctoken: String
    let sessionId: String
    let sessionIdSig: String
}

enum ChromeCookieService {
    private static let cookiesDBPath: String = {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return "\(home)/Library/Application Support/Google/Chrome/Default/Cookies"
    }()

    private static let cookieNames = ["ctoken", "sessionId", "sessionId.sig"]

    /// Extract ZenMux cookies from Chrome's encrypted cookie store.
    static func extractZenMuxCookies() throws -> ZenMuxCookies {
        // 1. Copy DB to temp to avoid WAL lock
        let tempDB = try copyDBToTemp()
        defer { try? FileManager.default.removeItem(atPath: tempDB) }

        // 2. Get Chrome Safe Storage key from Keychain
        let chromeKey = try readChromeSafeStorageKey()

        // 3. Derive decryption key via PBKDF2
        let derivedKey = try deriveKey(from: chromeKey)

        // 4. Read and decrypt cookies from SQLite
        let (rawCookies, dbVersion) = try readEncryptedCookies(dbPath: tempDB)

        var decrypted: [String: String] = [:]
        for (name, encryptedValue) in rawCookies {
            decrypted[name] = try decryptCookieValue(encryptedValue, key: derivedKey, dbVersion: dbVersion)
        }

        guard let ctoken = decrypted["ctoken"] else {
            throw ChromeCookieError.cookieNotFound("ctoken")
        }
        guard let sessionId = decrypted["sessionId"] else {
            throw ChromeCookieError.cookieNotFound("sessionId")
        }
        guard let sessionIdSig = decrypted["sessionId.sig"] else {
            throw ChromeCookieError.cookieNotFound("sessionId.sig")
        }

        return ZenMuxCookies(ctoken: ctoken, sessionId: sessionId, sessionIdSig: sessionIdSig)
    }

    // MARK: - DB Copy

    private static func copyDBToTemp() throws -> String {
        guard FileManager.default.fileExists(atPath: cookiesDBPath) else {
            throw ChromeCookieError.chromeNotInstalled
        }

        let tempDir = FileManager.default.temporaryDirectory
        let dest = tempDir.appendingPathComponent("TokenPulse_Cookies_\(UUID().uuidString)").path

        do {
            try FileManager.default.copyItem(atPath: cookiesDBPath, toPath: dest)
        } catch {
            throw ChromeCookieError.dbCopyFailed
        }
        return dest
    }

    // MARK: - Keychain

    private static func readChromeSafeStorageKey() throws -> String {
        let data = try KeychainService.readGenericPassword(service: "Chrome Safe Storage")
        guard let password = String(data: data, encoding: .utf8) else {
            throw ChromeCookieError.keychainFailed
        }
        return password
    }

    // MARK: - PBKDF2 Key Derivation

    private static func deriveKey(from password: String) throws -> Data {
        let salt = "saltysalt".data(using: .utf8)!
        let iterations: UInt32 = 1003
        let keyLength = 16 // AES-128

        var derivedKey = Data(count: keyLength)
        let passwordData = password.data(using: .utf8)!

        let status = derivedKey.withUnsafeMutableBytes { derivedKeyBytes in
            passwordData.withUnsafeBytes { passwordBytes in
                salt.withUnsafeBytes { saltBytes in
                    CCKeyDerivationPBKDF(
                        CCPBKDFAlgorithm(kCCPBKDF2),
                        passwordBytes.baseAddress?.assumingMemoryBound(to: Int8.self),
                        passwordData.count,
                        saltBytes.baseAddress?.assumingMemoryBound(to: UInt8.self),
                        salt.count,
                        CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA1),
                        iterations,
                        derivedKeyBytes.baseAddress?.assumingMemoryBound(to: UInt8.self),
                        keyLength
                    )
                }
            }
        }

        guard status == kCCSuccess else {
            throw ChromeCookieError.keyDerivationFailed
        }
        return derivedKey
    }

    // MARK: - SQLite Cookie Read

    private static func readEncryptedCookies(dbPath: String) throws -> (cookies: [(String, Data)], dbVersion: Int) {
        var db: OpaquePointer?
        guard sqlite3_open_v2(dbPath, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            let msg = db.flatMap { String(cString: sqlite3_errmsg($0)) } ?? "unknown"
            sqlite3_close(db)
            throw ChromeCookieError.dbOpenFailed(msg)
        }
        defer { sqlite3_close(db) }

        // Read DB version from meta table
        var dbVersion = 0
        var metaStmt: OpaquePointer?
        if sqlite3_prepare_v2(db, "SELECT value FROM meta WHERE key = 'version'", -1, &metaStmt, nil) == SQLITE_OK {
            if sqlite3_step(metaStmt) == SQLITE_ROW, let ptr = sqlite3_column_text(metaStmt, 0) {
                dbVersion = Int(String(cString: ptr)) ?? 0
            }
            sqlite3_finalize(metaStmt)
        }

        let query = """
            SELECT name, encrypted_value FROM cookies
            WHERE host_key LIKE '%zenmux%'
            AND name IN ('ctoken', 'sessionId', 'sessionId.sig')
            """

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, query, -1, &stmt, nil) == SQLITE_OK else {
            let msg = String(cString: sqlite3_errmsg(db))
            throw ChromeCookieError.dbOpenFailed(msg)
        }
        defer { sqlite3_finalize(stmt) }

        var results: [(String, Data)] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let namePtr = sqlite3_column_text(stmt, 0) else { continue }
            let name = String(cString: namePtr)

            let blobLen = sqlite3_column_bytes(stmt, 1)
            guard blobLen > 0, let blobPtr = sqlite3_column_blob(stmt, 1) else { continue }
            let data = Data(bytes: blobPtr, count: Int(blobLen))

            results.append((name, data))
        }

        return (results, dbVersion)
    }

    // MARK: - AES-128-CBC Decryption

    private static func decryptCookieValue(_ encrypted: Data, key: Data, dbVersion: Int) throws -> String {
        // Chrome v10/v11 encrypted cookies start with "v10" or "v11" (3 bytes)
        let payload: Data
        if encrypted.starts(with: "v10".data(using: .utf8)!) ||
           encrypted.starts(with: "v11".data(using: .utf8)!) {
            payload = encrypted.dropFirst(3)
        } else {
            // Might be plaintext
            if let str = String(data: encrypted, encoding: .utf8) {
                return str
            }
            throw ChromeCookieError.decryptionFailed
        }

        // IV: 16 bytes of 0x20 (space character)
        let iv = Data(repeating: 0x20, count: kCCBlockSizeAES128)

        // Decrypt without auto-padding so we can handle the prefix strip manually
        let bufferSize = payload.count + kCCBlockSizeAES128
        var decrypted = Data(count: bufferSize)

        var outLength = 0
        let status = payload.withUnsafeBytes { payloadBytes in
            key.withUnsafeBytes { keyBytes in
                iv.withUnsafeBytes { ivBytes in
                    decrypted.withUnsafeMutableBytes { decryptedBytes in
                        CCCrypt(
                            CCOperation(kCCDecrypt),
                            CCAlgorithm(kCCAlgorithmAES),
                            CCOptions(0),  // No auto-padding — we strip PKCS7 manually
                            keyBytes.baseAddress, kCCKeySizeAES128,
                            ivBytes.baseAddress,
                            payloadBytes.baseAddress, payload.count,
                            decryptedBytes.baseAddress, bufferSize,
                            &outLength
                        )
                    }
                }
            }
        }

        guard status == kCCSuccess else {
            throw ChromeCookieError.decryptionFailed
        }

        decrypted.removeSubrange(outLength..<decrypted.count)

        // DB version >= 24: first 32 bytes are an extra prefix, skip them
        if dbVersion >= 24 && decrypted.count > 32 {
            decrypted = decrypted.dropFirst(32)
        }

        // Manual PKCS7 padding removal
        guard let lastByte = decrypted.last else {
            throw ChromeCookieError.decryptionFailed
        }
        let padLen = Int(lastByte)
        if padLen > 0 && padLen <= kCCBlockSizeAES128 && decrypted.count >= padLen {
            decrypted.removeLast(padLen)
        }

        guard let result = String(data: decrypted, encoding: .utf8) else {
            throw ChromeCookieError.decryptionFailed
        }
        return result
    }
}
