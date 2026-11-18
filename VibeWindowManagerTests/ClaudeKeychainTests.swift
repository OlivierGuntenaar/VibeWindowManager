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

    @Test func lockedAndDeniedCredentialsAreNeverReportedMissing() async {
        for result in [ClaudeKeychain.ReadResult.locked, .approvalRequired, .unavailable] {
            let lookup = await ClaudeUsageFetcher.lookUpCredential(keychainRead: { result }, fileRead: { nil })
            guard case .inaccessible(let message) = lookup else { Issue.record("Access failure reported as absent"); continue }
            #expect(!message.contains("not found"))
            let snapshot = await ClaudeUsageFetcher.loadSnapshot(credentialLookup: { lookup }, transport: { _ in
                Issue.record("Access failure contacted usage API"); throw URLError(.cancelled)
            }, configPlan: { nil }, renewCredential: { _ in
                Issue.record("Access failure attempted token renewal"); return .failed(.init())
            })
            #expect(snapshot.requiresKeychainAccess)
        }
    }

    @Test func usableFileCredentialSurvivesKeychainDenial() async {
        let lookup = await ClaudeUsageFetcher.lookUpCredential(keychainRead: { .approvalRequired }, fileRead: {
            Data(#"{"claudeAiOauth":{"accessToken":"fixture-file"}}"#.utf8)
        })
        guard case .found(let value) = lookup else { Issue.record("File fallback lost"); return }
        #expect(value.accessToken == "fixture-file")
    }

    @Test func oversizedAndMultilineCommandsFailBeforeWriting() {
        #expect(ClaudeKeychain.updateCommand(account: "fixture", service: "fixture", data: Data(repeating: 120, count: 12000)) == nil)
        #expect(ClaudeKeychain.updateCommand(account: "fixture\nhelp", service: "fixture", data: Data("{}".utf8)) == nil)
        #expect(ClaudeKeychain.updateCommand(account: "fixture", service: "fixture", data: Data("{}\nhelp".utf8)) == nil)
        let unicode = Data(String(repeating: "🧪", count: 2000).utf8)
        #expect(ClaudeKeychain.updateCommand(account: "fixture", service: "fixture", data: unicode) == nil)
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

    @Test func realKeychainWritesRetainTrustAcrossRepeatedRenewals() async throws {
        try await withFixture { service in
            for revision in 1...3 {
                let data = try JSONSerialization.data(withJSONObject: ["revision": revision,
                    "fixture": String(repeating: "quoted\" \\ résumé 🧪 $HOME", count: 20)])
                #expect(ClaudeKeychain.access(service: service) == .ready(NSUserName()))
                #expect(await ClaudeKeychain.update(account: NSUserName(), service: service, data: data))
                #expect(ClaudeKeychain.access(service: service) == .ready(NSUserName()))
                let read = await ClaudeKeychain.run(["find-generic-password", "-a", NSUserName(), "-s", service, "-w"], timeout: 5)
                #expect(read.data == data)
            }
            let before = await ClaudeKeychain.run(["find-generic-password", "-a", NSUserName(), "-s", service, "-w"], timeout: 5)
            #expect(!(await ClaudeKeychain.update(account: NSUserName(), service: service, data: Data(repeating: 120, count: 12000))))
            let after = await ClaudeKeychain.run(["find-generic-password", "-a", NSUserName(), "-s", service, "-w"], timeout: 5)
            #expect(after.data == before.data)
        }
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
