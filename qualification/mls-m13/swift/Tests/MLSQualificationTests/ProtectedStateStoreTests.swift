import CryptoKit
import Foundation
import Security
import XCTest
@testable import ProtectedStateStore

private final class MemoryAnchorStore: StateAnchorStore {
    var value: StateAnchor?

    func create(_ anchor: StateAnchor) throws {
        guard value == nil else { throw ProtectedStateError.alreadyExists }
        value = anchor
    }

    func load() throws -> StateAnchor {
        guard let value else { throw ProtectedStateError.unavailable }
        return value
    }

    func replace(_ anchor: StateAnchor) throws {
        guard value != nil else { throw ProtectedStateError.unavailable }
        value = anchor
    }
}

final class ProtectedStateStoreTests: XCTestCase {
    private func temporaryFile() throws -> URL {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("watchlink-m12-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder.appendingPathComponent("state.aead")
    }

    func testSealOpenAndRestart() throws {
        let anchor = MemoryAnchorStore()
        let file = try temporaryFile()
        let store = ProtectedStateStore(anchorStore: anchor, fileURL: file)
        try store.create()
        let version = try store.reserve()
        try store.commit(opaqueMLSState: Data("opaque fixture".utf8), version: version)
        let restarted = ProtectedStateStore(anchorStore: anchor, fileURL: file)
        XCTAssertEqual(try restarted.restore(), Data("opaque fixture".utf8))
        let onDisk = try Data(contentsOf: file)
        XCTAssertFalse(String(decoding: onDisk, as: UTF8.self).contains("opaque fixture"))
    }

    func testTamperAndWrongKeyFailClosed() throws {
        let anchor = MemoryAnchorStore()
        let file = try temporaryFile()
        let store = ProtectedStateStore(anchorStore: anchor, fileURL: file)
        try store.create()
        try store.commit(opaqueMLSState: Data([1, 2, 3]), version: store.reserve())

        let original = try Data(contentsOf: file)
        var corrupted = original
        corrupted[corrupted.index(before: corrupted.endIndex)] ^= 1
        try corrupted.write(to: file, options: [.atomic, .completeFileProtection])
        XCTAssertThrowsError(try store.restore())

        try original.write(to: file, options: [.atomic, .completeFileProtection])
        var changed = try anchor.load()
        changed.storageKey = SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }
        try anchor.replace(changed)
        XCTAssertThrowsError(try store.restore())
    }

    func testRollbackAndPendingFailClosed() throws {
        let anchor = MemoryAnchorStore()
        let file = try temporaryFile()
        let store = ProtectedStateStore(anchorStore: anchor, fileURL: file)
        try store.create()
        try store.commit(opaqueMLSState: Data([1]), version: store.reserve())
        let older = try Data(contentsOf: file)
        try store.commit(opaqueMLSState: Data([2]), version: store.reserve())
        try older.write(to: file, options: [.atomic, .completeFileProtection])
        XCTAssertThrowsError(try store.restore())

        let pending = try store.reserve()
        XCTAssertEqual(pending, 3)
        XCTAssertThrowsError(try store.restore())
    }

    func testKeychainAnchorAccessibility() throws {
        let service = "dev.watchlink.m12.test.\(UUID().uuidString)"
        let account = "anchor"
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        defer { SecItemDelete(query as CFDictionary) }
        let anchor = KeychainStateAnchorStore(service: service, account: account)
        let file = try temporaryFile()
        let store = ProtectedStateStore(anchorStore: anchor, fileURL: file)
        try store.create()
        try store.commit(opaqueMLSState: Data([9, 8, 7]), version: store.reserve())
        XCTAssertEqual(try store.restore(), Data([9, 8, 7]))

        var attributesQuery = query
        attributesQuery[kSecReturnAttributes as String] = true
        var result: CFTypeRef?
        XCTAssertEqual(SecItemCopyMatching(attributesQuery as CFDictionary, &result), errSecSuccess)
        let attributes = try XCTUnwrap(result as? [String: Any])
        XCTAssertEqual(
            attributes[kSecAttrAccessible as String] as? String,
            kSecAttrAccessibleWhenUnlockedThisDeviceOnly as String
        )
    }
}
