import Foundation
import Security

/// Claude Code uses Apple's security tool. Use that same identity for reads AND writes:
/// a native SecItemUpdate rewrites the partition list to this app's ad-hoc signing hash.
nonisolated enum ClaudeKeychain {
    enum Access: Equatable, Sendable { case ready(String), missing, locked, approvalRequired, unavailable }
    enum ReadResult: Sendable { case found(String, Data), missing, locked, approvalRequired, unavailable }
    static let blockedKey = "claudeUsage.keychainAccessBlocked"
    private static let metadataLock = NSLock()

    static func access(service: String = ClaudeUsageFetcher.keychainService) -> Access {
        metadataLock.withLock {
            var wasAllowed: DarwinBoolean = true
            guard SecKeychainGetUserInteractionAllowed(&wasAllowed) == errSecSuccess,
                  SecKeychainSetUserInteractionAllowed(false) == errSecSuccess else { return .unavailable }
            defer { SecKeychainSetUserInteractionAllowed(wasAllowed.boolValue) }
            var query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service, kSecAttrAccount as String: NSUserName(),
                kSecReturnAttributes as String: true, kSecReturnRef as String: true,
                kSecMatchLimit as String: kSecMatchLimitOne]
            var result: CFTypeRef?
            var status = SecItemCopyMatching(query as CFDictionary, &result)
            if status == errSecItemNotFound {
                query.removeValue(forKey: kSecAttrAccount as String)
                status = SecItemCopyMatching(query as CFDictionary, &result)
            }
            if status == errSecItemNotFound { return .missing }
            guard status == errSecSuccess, let values = result as? [String: Any],
                  let account = values[kSecAttrAccount as String] as? String,
                  let reference = values[kSecValueRef as String] else { return .unavailable }
            let item = reference as! SecKeychainItem
            var keychain: SecKeychain?
            var keychainStatus: SecKeychainStatus = 0
            guard SecKeychainItemCopyKeychain(item, &keychain) == errSecSuccess,
                  let keychain, SecKeychainGetStatus(keychain, &keychainStatus) == errSecSuccess else { return .unavailable }
            guard keychainStatus & kSecUnlockStateStatus != 0 else { return .locked }
            var access: SecAccess?
            var list: CFArray?
            guard SecKeychainItemCopyAccess(item, &access) == errSecSuccess, let access,
                  SecAccessCopyACLList(access, &list) == errSecSuccess,
                  let acls = list as? [SecACL] else { return .approvalRequired }
            var trusted = false
            var allowedPartition = true
            for acl in acls {
                let authorizations = SecACLCopyAuthorizations(acl) as? [String] ?? []
                var apps: CFArray?
                var description: CFString?
                var prompt = SecKeychainPromptSelector()
                guard SecACLCopyContents(acl, &apps, &description, &prompt) == errSecSuccess else { return .approvalRequired }
                if authorizations.contains(kSecACLAuthorizationDecrypt as String) {
                    // An absent application list allows all applications; an empty list allows none.
                    trusted = prompt.rawValue == 0 && (apps == nil || (apps as? [SecTrustedApplication] ?? []).contains {
                        var data: CFData?
                        guard SecTrustedApplicationCopyData($0, &data) == errSecSuccess, let data,
                              let path = String(data: data as Data, encoding: .utf8) else { return false }
                        return path.trimmingCharacters(in: .controlCharacters) == "/usr/bin/security"
                    })
                }
                if authorizations.contains(kSecACLAuthorizationPartitionID as String) {
                    allowedPartition = permitsSecurityTool(partitionDescription: description as String?)
                }
            }
            return trusted && allowedPartition ? .ready(account) : .approvalRequired
        }
    }

    static func permitsSecurityTool(partitionDescription: String?) -> Bool {
        guard let text = partitionDescription, let bytes = decodeHex(text) else { return false }
        guard let value = try? PropertyListSerialization.propertyList(from: bytes, format: nil) as? [String: Any],
              let partitions = value["Partitions"] as? [String] else { return false }
        return partitions.contains("apple-tool:") || partitions.contains("apple:")
    }

    private static func decodeHex(_ text: String) -> Data? {
        guard !text.isEmpty, text.count.isMultiple(of: 2) else { return nil }
        var bytes = Data()
        var index = text.startIndex
        while index < text.endIndex {
            let next = text.index(index, offsetBy: 2)
            guard let byte = UInt8(text[index..<next], radix: 16) else { return nil }
            bytes.append(byte); index = next
        }
        return bytes
    }

    @concurrent static func read(allowInteraction: Bool = false, defaults: UserDefaults = .standard,
                                 service: String = ClaudeUsageFetcher.keychainService) async -> ReadResult {
        let state = access(service: service)
        if state == .missing { return .missing }
        if !allowInteraction {
            if state == .locked { return .locked }
            if state == .unavailable { return .unavailable }
            if state == .approvalRequired || defaults.bool(forKey: blockedKey) { return .approvalRequired }
        }
        let account: String?
        if case .ready(let name) = state { account = name } else { account = nil }
        var arguments = ["find-generic-password", "-w", "-s", service]
        if let account { arguments += ["-a", account] }
        let result = await run(arguments, timeout: allowInteraction ? nil : 10)
        guard result.status == 0, let data = result.data, !data.isEmpty else {
            // A timeout/denial is not absence. Never repeat an interactive attempt on the next poll.
            defaults.set(true, forKey: blockedKey)
            return .approvalRequired
        }
        defaults.removeObject(forKey: blockedKey)
        let resolvedAccount: String
        if let account { resolvedAccount = account }
        else if case .ready(let name) = access(service: service) { resolvedAccount = name }
        else { defaults.set(true, forKey: blockedKey); return .approvalRequired }
        return .found(resolvedAccount, data)
    }

    /// security's interactive parser has a 4096-byte buffer. Fail before starting a process if
    /// the ENTIRE encoded command won't fit; never truncate credentials or put secrets in argv.
    static func updateCommand(account: String, service: String, data: Data) -> Data? {
        guard let json = String(data: data, encoding: .utf8), !json.contains("\n"), !json.contains("\r"), !json.contains("\0") else { return nil }
        func quote(_ value: String) -> String {
            "\"" + value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
        }
        guard !account.contains(where: { $0.isNewline || $0 == "\0" }), !service.contains(where: { $0.isNewline || $0 == "\0" }) else { return nil }
        let command = Data("add-generic-password -U -a \(quote(account)) -s \(quote(service)) -w \(quote(json))\n".utf8)
        return command.count < 4096 ? command : nil
    }

    @concurrent static func update(account: String, service: String, data: Data) async -> Bool {
        guard let command = updateCommand(account: account, service: service, data: data),
              case .ready(let current) = access(service: service), current == account else { return false }
        let result = await run(["-i"], input: command, timeout: 10)
        return result.status == 0
    }

    struct ProcessResult: Sendable { let status: Int32; let data: Data? }
    @concurrent static func run(_ arguments: [String], input: Data? = nil, timeout: TimeInterval?) async -> ProcessResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = arguments
        let output = Pipe()
        let stdin = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        process.standardInput = input == nil ? FileHandle.nullDevice : stdin.fileHandleForReading
        do { try process.run() } catch { return ProcessResult(status: -1, data: nil) }
        let deadline = DispatchWorkItem { if process.isRunning { process.terminate() } }
        if let timeout { DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: deadline) }
        defer { deadline.cancel() }
        if let input {
            do { try stdin.fileHandleForWriting.write(contentsOf: input); try stdin.fileHandleForWriting.close() }
            catch { process.terminate() }
        }
        var data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        while let last = data.last, last == 10 || last == 13 { data.removeLast() }
        // security prints non-ASCII password data as hex, including JSON with Unicode names.
        if arguments.first == "find-generic-password", let text = String(data: data, encoding: .utf8),
           let decoded = decodeHex(text), (try? JSONSerialization.jsonObject(with: decoded)) != nil {
            data = decoded
        }
        return ProcessResult(status: process.terminationStatus, data: data.isEmpty ? nil : data)
    }
}
