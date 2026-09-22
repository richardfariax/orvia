import CryptoKit
import Foundation

enum LocalCryptoError: LocalizedError {
    case invalidStoredKeyLength(Int)
    case failedToPersistKey
    case failedToCreateEncryptedPayload

    var errorDescription: String? {
        switch self {
        case .invalidStoredKeyLength(let length):
            return "Chave local inválida no Keychain (tamanho: \(length) bytes)"
        case .failedToPersistKey:
            return "Falha ao persistir chave local no Keychain"
        case .failedToCreateEncryptedPayload:
            return "Falha ao gerar payload criptografado"
        }
    }
}

final class LocalCryptoService {
    // Keep the original Keychain service so encrypted history survives the rebrand.
    private let serviceName = "com.clipflow.local-crypto"
    private let accountName = "primary-key"
    private var cachedKey: SymmetricKey?

    private func resolveKey() throws -> SymmetricKey {
        if let cachedKey {
            return cachedKey
        }

        if let existing = KeychainHelper.loadData(service: serviceName, account: accountName) {
            guard existing.count == 32 else {
                throw LocalCryptoError.invalidStoredKeyLength(existing.count)
            }
            let key = SymmetricKey(data: existing)
            cachedKey = key
            return key
        }

        let newKey = SymmetricKey(size: .bits256)
        let keyData = newKey.withUnsafeBytes { Data($0) }
        guard KeychainHelper.saveData(keyData, service: serviceName, account: accountName) else {
            throw LocalCryptoError.failedToPersistKey
        }
        cachedKey = newKey
        return newKey
    }

    func encrypt(_ data: Data) throws -> Data {
        let sealed = try AES.GCM.seal(data, using: resolveKey())
        guard let combined = sealed.combined else {
            throw LocalCryptoError.failedToCreateEncryptedPayload
        }
        return combined
    }

    func decrypt(_ data: Data) throws -> Data {
        let box = try AES.GCM.SealedBox(combined: data)
        return try AES.GCM.open(box, using: resolveKey())
    }
}
