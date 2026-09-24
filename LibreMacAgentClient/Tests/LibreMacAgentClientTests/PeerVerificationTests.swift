// SPDX-License-Identifier: LGPL-2.1-or-later
// SPDX-FileCopyrightText: 2026 hirashix0

import Darwin
import Foundation
import Security
import Testing
@testable import LibreMacAgentClient

/// A listening AF_UNIX socket in a private temporary directory: the stand-in
/// for whatever process serves the agent path. It never writes; tests read
/// what the client sent it.
private final class TestListener {
    let path: String
    private let directory: String
    private let fd: Int32

    init() throws {
        var template = Array((NSTemporaryDirectory() as NSString).appendingPathComponent("lmpv.XXXXXX").utf8CString)
        guard let made = mkdtemp(&template) else { throw POSIXError(.EIO) }
        directory = String(cString: made)
        path = directory + "/s"
        fd = socket(AF_UNIX, SOCK_STREAM, 0)
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        precondition(bytes.count < MemoryLayout.size(ofValue: addr.sun_path))
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in
            for (index, byte) in bytes.enumerated() { raw[index] = byte }
        }
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bound == 0, listen(fd, 8) == 0 else { throw POSIXError(.EIO) }
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL, 0) | O_NONBLOCK)
    }

    deinit {
        close(fd)
        unlink(path)
        rmdir(directory)
    }

    /// Accepts one connection within `timeout` and returns how many bytes the
    /// client wrote before closing it; nil when nobody connected.
    func bytesFromNextConnection(timeout: TimeInterval = 3) -> Int? {
        let deadline = Date().addingTimeInterval(timeout)
        var conn: Int32 = -1
        while conn < 0 {
            conn = accept(fd, nil, nil)
            if conn < 0 {
                if Date() > deadline { return nil }
                usleep(10_000)
            }
        }
        defer { close(conn) }
        _ = fcntl(conn, F_SETFL, fcntl(conn, F_GETFL, 0) & ~O_NONBLOCK)
        var tv = timeval(tv_sec: 3, tv_usec: 0)
        _ = setsockopt(conn, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        var total = 0
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let n = read(conn, &buffer, buffer.count)
            if n <= 0 { break }
            total += n
        }
        return total
    }
}

/// The code-signing identifier of this test process, read from its own code
/// (a different API from the SecTask path under test).
private func selfSigningIdentifier() throws -> String {
    var code: SecCode?
    guard SecCodeCopySelf([], &code) == errSecSuccess, let code else { throw POSIXError(.EIO) }
    var staticCode: SecStaticCode?
    guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode else {
        throw POSIXError(.EIO)
    }
    var info: CFDictionary?
    guard SecCodeCopySigningInformation(staticCode, [], &info) == errSecSuccess,
        let dict = info as? [String: Any],
        let identifier = dict[kSecCodeInfoIdentifier as String] as? String
    else { throw POSIXError(.EIO) }
    return identifier
}

private func socketPair() -> (Int32, Int32) {
    var pair: [Int32] = [0, 0]
    precondition(socketpair(AF_UNIX, SOCK_STREAM, 0, &pair) == 0)
    return (pair[0], pair[1])
}

/// Counts verifier calls from any thread.
private final class CallCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    func increment() {
        lock.lock()
        value += 1
        lock.unlock()
    }
    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}

@Suite("PeerVerification")
struct PeerVerificationTests {

    // MARK: - The client refuses before it speaks

    @Test("ClientRefusesAServerTheVerifierRejects: no Hello, the connect counts as failed")
    func clientRefusesAServerTheVerifierRejects() async throws {
        let mock = MockAgentServer()
        let client = makeTestClient(mock: mock, verifier: { _ in false })
        await client.start()

        // Two refusals prove the supervisor treated the first as a failed
        // connect and came back to check again, not that it gave up silently.
        let deadline = Date().addingTimeInterval(3)
        while mock.rejectedConnectionCount < 2, Date() < deadline {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        #expect(mock.rejectedConnectionCount >= 2)
        #expect(mock.count(of: "Hello") == 0)
        #expect(await client.isAvailable() == false)
        await client.stop()
    }

    @Test("the public AgentClient init runs its verifier on the served socket and writes nothing to a refused one")
    func agentClientPublicInitRefusesBeforeWriting() async throws {
        let listener = try TestListener()
        let calls = CallCounter()
        let client = AgentClient(
            socketPath: listener.path, clientVersion: "LibreMac/test", initialBackoff: 0.05, maxBackoff: 0.2,
            verifier: { _ in
                calls.increment()
                return false
            })
        await client.start()
        let written = listener.bytesFromNextConnection()
        await client.stop()
        #expect(written == 0)
        #expect(calls.count >= 1)
        #expect(await client.isAvailable() == false)
    }

    @Test("SocketConnection.connect refuses a rejected server with peerRejected")
    func socketConnectionConnectRefuses() throws {
        let listener = try TestListener()
        #expect(throws: SocketConnectionError.peerRejected) {
            _ = try SocketConnection.connect(path: listener.path, verifier: { _ in false })
        }
        #expect(listener.bytesFromNextConnection() == 0)
    }

    // MARK: - The default verifier

    @Test("DefaultVerifierRejectsAnUnsignedPeer: this test process is not the agent")
    func defaultVerifierRejectsAnUnsignedPeer() {
        let (a, b) = socketPair()
        defer {
            close(a)
            close(b)
        }
        #expect(defaultPeerVerifier()(a) == false)
        #expect(defaultPeerVerifier(teamId: "ABCDE12345")(a) == false)
    }

    @Test("the default verifier refuses the production connect path to this process")
    func defaultVerifierOnTheConnectPath() throws {
        let listener = try TestListener()
        #expect(throws: SocketConnectionError.peerRejected) {
            _ = try SocketConnection.connect(path: listener.path)
        }
        #expect(throws: TokenTransportError.peerRejected) {
            _ = try TokenAgentClient(socketPath: listener.path)
        }
    }

    @Test("resolution reads the serving process's real signing identifier")
    func resolutionReadsTheServingProcessesIdentity() throws {
        let (a, b) = socketPair()
        defer {
            close(a)
            close(b)
        }
        let token = try #require(peerAuditToken(a))
        let resolved = resolvePeerCodeSigning(auditToken: token, teamId: nil)
        let own = try selfSigningIdentifier()
        #expect(resolved.signingId == own)
        #expect(resolved.designatedRequirementValid == nil)
        // With a team id the requirement is evaluated, and this process was
        // not signed by that team.
        #expect(resolvePeerCodeSigning(auditToken: token, teamId: "ABCDE12345").designatedRequirementValid == false)
        // The identifier alone is not enough: this process has no App Group.
        #expect(verifyConnectedPeer(a, expected: ExpectedPeerIdentity(signingId: own, appGroup: "group.org.librescrs.LibreMac")) == false)
    }

    @Test("an fd with no peer is refused")
    func unreadablePeerIsRefused() {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        defer { close(fd) }
        #expect(peerAuditToken(fd) == nil)
        #expect(defaultPeerVerifier()(fd) == false)
    }

    // MARK: - Policy (pure)

    @Test("policy: identifier and App Group both required; a configured team needs the requirement to hold")
    func policy() {
        let expected = ExpectedPeerIdentity(signingId: "org.librescrs.agent", appGroup: "group.org.librescrs.LibreMac")
        let good = PeerCodeSigning(signingId: "org.librescrs.agent", appGroups: ["group.org.librescrs.LibreMac"])
        #expect(matchesExpectedPeer(good, expected))
        #expect(!matchesExpectedPeer(PeerCodeSigning(signingId: nil, appGroups: good.appGroups), expected))
        #expect(!matchesExpectedPeer(PeerCodeSigning(signingId: "librescrs-agent", appGroups: good.appGroups), expected))
        #expect(!matchesExpectedPeer(PeerCodeSigning(signingId: "org.librescrs.agent", appGroups: []), expected))
        #expect(!matchesExpectedPeer(
            PeerCodeSigning(signingId: "org.librescrs.agent", appGroups: ["group.other"]), expected))

        var teamed = expected
        teamed.teamId = "ABCDE12345"
        #expect(!matchesExpectedPeer(good, teamed)) // not evaluated counts as failed
        var failed = good
        failed.designatedRequirementValid = false
        #expect(!matchesExpectedPeer(failed, teamed))
        var held = good
        held.designatedRequirementValid = true
        #expect(matchesExpectedPeer(held, teamed))
    }

    @Test("the designated requirement text is the agent's, and nothing can be pasted into it")
    func designatedRequirementText() {
        #expect(
            designatedRequirement(teamId: "ABCDE12345", signingId: "org.librescrs.agent")
                == "anchor apple generic and certificate leaf[subject.OU] = \"ABCDE12345\" and identifier \"org.librescrs.agent\"")
        #expect(designatedRequirement(teamId: "", signingId: "org.librescrs.agent") == nil)
        #expect(designatedRequirement(teamId: "ABCDE12345", signingId: "") == nil)
        #expect(designatedRequirement(teamId: "ABC\" or true", signingId: "org.librescrs.agent") == nil)
        #expect(designatedRequirement(teamId: "ABCDE12345", signingId: "a\" or identifier \"b") == nil)
        #expect(designatedRequirement(teamId: "ABCDE.12345", signingId: "org.librescrs.agent") == nil)
    }

    @Test("the compiled-in team id is the project's DEVELOPMENT_TEAM")
    func configuredTeamIdMatchesTheProject() throws {
        let projectYml = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("project.yml")
        let text = try String(contentsOf: projectYml, encoding: .utf8)
        let values = text.split(separator: "\n").compactMap { line -> String? in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("DEVELOPMENT_TEAM:") else { return nil }
            return trimmed.dropFirst("DEVELOPMENT_TEAM:".count)
                .trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
        }
        #expect(values.count == 1, "project.yml states DEVELOPMENT_TEAM once")
        #expect(values.first == AgentPeerIdentity.configuredTeamIdentifier)
        #expect(AgentPeerIdentity.configuredTeamIdentifier.allSatisfy { $0.isASCII && ($0.isUppercase || $0.isNumber) })
    }

    // MARK: - The token path

    @Test("the token client refuses a rejected server and writes nothing")
    func tokenClientRefuses() throws {
        let listener = try TestListener()
        #expect(throws: TokenTransportError.peerRejected) {
            _ = try TokenAgentClient(socketPath: listener.path, verifier: { _ in false })
        }
        #expect(listener.bytesFromNextConnection() == 0)
    }

    @Test("the token path does not retry a rejected server")
    func tokenPathDoesNotRetryARejectedServer() throws {
        let listener = try TestListener()
        let calls = CallCounter()
        let unit = ReconnectingTokenEngine(connect: {
            calls.increment()
            return try TokenAgentClient(socketPath: listener.path, verifier: { _ in false })
        })
        #expect(throws: TokenOpError.mapped(.communicationError)) {
            _ = try unit.withEngine { try $0.sign(certId: "cert", digestInfo: Data([0x30]), requireFreshAuth: true) }
        }
        #expect(calls.count == 1)
        #expect(listener.bytesFromNextConnection() == 0)
        #expect(listener.bytesFromNextConnection(timeout: 0.2) == nil, "exactly one connection was made")
        #expect(!ReconnectingTokenEngine.isConnectionLoss(.peerRejected))
    }

    @Test("a reconnect after a lost connection is checked too, and a refusal ends the operation")
    func tokenReconnectIsVerified() throws {
        let server = MockAgentServer()
        server.onRequest = { [unowned server] _, tag in
            if tag == "GetState" { server.dropRawConnection() }
        }
        let listener = try TestListener()
        let calls = CallCounter()
        let unit = ReconnectingTokenEngine(connect: {
            calls.increment()
            if calls.count == 1 { return TokenAgentClient(connectedFd: server.connectedFd(), ioTimeout: 5) }
            return try TokenAgentClient(socketPath: listener.path, verifier: { _ in false })
        })
        #expect(throws: TokenOpError.mapped(.communicationError)) {
            _ = try unit.withEngine { try $0.sign(certId: "cert", digestInfo: Data([0x30]), requireFreshAuth: true) }
        }
        #expect(calls.count == 2)
        #expect(listener.bytesFromNextConnection() == 0)
        #expect(listener.bytesFromNextConnection(timeout: 0.2) == nil)
    }
}
