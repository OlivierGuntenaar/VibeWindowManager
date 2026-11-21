import Foundation
import Security
import Testing
@testable import VibeWindowManager

struct ClaudeKeychainTests {
    private func partition(_ names: [String]) throws -> String {
        try PropertyListSerialization.data(fromPropertyList: ["Partitions": names], format: .xml, options: 0)
            .map { String(format: "%02x", $0) }.joined()
    }

    @Test func onlyApplePartitionsPermitBackgroundToolAccess() throws {
        #expect(ClaudeKeychain.permitsSecurityTool(partitionDescription: try partition(["apple-tool:"])))
        #expect(ClaudeKeychain.permitsSecurityTool(partitionDescription: try partition(["apple:"])))
        #expect(!ClaudeKeychain.permitsSecurityTool(partitionDescription: try partition(["cdhash:unrelated-app"])))
        for invalid in [nil, "", "garbage", "00"] as [String?] {
            #expect(!ClaudeKeychain.permitsSecurityTool(partitionDescription: invalid))
        }
    }

    private func withFixture(_ body: (String) async throws -> Void) async throws {
        let service = "VibeWindowManager-KeychainTest-\(UUID().uuidString)"
        let created = await ClaudeKeychain.run(["add-generic-password", "-a", NSUserName(), "-s", service, "-w", "fixture"], timeout: 5)
        try #require(created.status == 0)
        do { try await body(service) }
        catch {
            _ = await ClaudeKeychain.run(["delete-generic-password", "-a", NSUserName(), "-s", service], timeout: 5)
            throw error
        }
        _ = await ClaudeKeychain.run(["delete-generic-password", "-a", NSUserName(), "-s", service], timeout: 5)
    }

    @Test func oldNativeWriterMismatchIsDetectedWithoutPrompting() async throws {
        try await withFixture { service in
            let status = SecItemUpdate([kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service, kSecAttrAccount as String: NSUserName()] as CFDictionary,
                [kSecValueData as String: Data("native-writer-fixture".utf8)] as CFDictionary)
            try #require(status == errSecSuccess)
            #expect(ClaudeKeychain.access(service: service) == .approvalRequired)
            let suite = "ClaudeKeychainTests.\(UUID().uuidString)"
            let defaults = try #require(UserDefaults(suiteName: suite))
            defer { defaults.removePersistentDomain(forName: suite) }
            for _ in 0..<3 {
                let read = await ClaudeKeychain.read(defaults: defaults, service: service)
                guard case .approvalRequired = read else { Issue.record("Untrusted tool was launched"); return }
            }
        }
    }
}
