// SPDX-License-Identifier: LGPL-2.1-or-later
// SPDX-FileCopyrightText: 2026 hirashix0

import Darwin
import Foundation
import Testing
@testable import LibreMacAgentClient

@Suite("AgentOperation")
struct AgentOperationTests {

    @Test("OpResultReady before OpFinished delivers the typed result")
    func opResultReadyBeforeOpFinishedDeliversTypedResult() async throws {
        let mock = MockAgentServer()
        let client = makeTestClient(mock: mock)
        var iterator = await startAndHandshake(mock, client)

        async let opTask = client.readIdentity(card: "c1")
        let startReq = try #require(await iterator.next())
        guard case .readIdentity = startReq.request else {
            Issue.record("expected ReadIdentity, got \(startReq.request)")
            return
        }
        mock.sendReply(.opStarted(op: 7), req: startReq.req)
        let operation = try await opTask

        let identity = IdentityResult(fields: [
            "personal": [
                "givenName": IdentityField(labelKey: "k.given", labelFallback: "Given name", type: "text", value: .text("Ana"))
            ]
        ])
        mock.sendEvent(.opResultReady(op: 7, result: .identity(identity)))
        mock.sendEvent(.opFinished(op: 7, status: .ok, code: .none, msgKey: "", msgFallback: "done"))

        let (status, code, msgKey, msgFallback) = await operation.finished()
        #expect(status == .ok)
        #expect(code == .none)
        #expect(msgKey == nil)
        #expect(msgFallback == "done")
        #expect(operation.identityResult == identity)
        #expect(operation.result == .identity(identity))

        await client.stop()
    }

    @Test("Sign OpFinished(ok) with no prior result triggers exactly one GetSignResult recovery call")
    func signRecoveryTriggersExactlyOnce() async throws {
        let mock = MockAgentServer()
        let client = makeTestClient(mock: mock)
        var iterator = await startAndHandshake(mock, client)

        let input = try #require(FileHandle(forReadingAtPath: "/dev/null"))
        defer { try? input.close() }
        async let opTask = client.sign(
            card: "c1", certId: "cert1", input: input,
            options: SignOptions(format: .pades, level: .bB, packaging: .enveloped))
        let startReq = try #require(await iterator.next())
        guard case .sign = startReq.request else {
            Issue.record("expected Sign, got \(startReq.request)")
            return
        }
        mock.sendReply(.opStarted(op: 42), req: startReq.req)
        let operation = try await opTask

        // OpFinished(ok) arrives with NO prior OpResultReady — this is the
        // hole in the ordering contract that Sign alone recovers from.
        mock.sendEvent(.opFinished(op: 42, status: .ok, code: .none, msgKey: "", msgFallback: ""))

        let recoveryReq = try #require(await iterator.next())
        guard case .getSignResult(let op) = recoveryReq.request else {
            Issue.record("expected a GetSignResult recovery call, got \(recoveryReq.request)")
            return
        }
        #expect(op == 42)

        let signResult = SignResult(
            artifact: 0, meta: SignMeta(format: "pades", level: "b-b", tsaUsed: false, chainComplete: true))
        mock.sendReply(.signRecovery(signResult), req: recoveryReq.req)

        let (status, code, _, _) = await operation.finished()
        #expect(status == .ok)
        #expect(code == .none)
        #expect(operation.signResult == signResult)

        // By the time `finished()` has resolved, the recovery call — sent
        // before the reply that unblocked it — has definitely already
        // been counted; the client only ever spawns one recovery attempt
        // per `OpFinished` (the op is removed from the live table before
        // the recovery `Task` is even spawned).
        #expect(mock.count(of: "GetSignResult") == 1)

        await client.stop()
    }

    @Test("ReadCertificates OpFinished(ok) with no result surfaces a loud .communicationError, never a silent empty success")
    func readCertificatesNoResultSurfacesLoudError() async throws {
        let mock = MockAgentServer()
        let client = makeTestClient(mock: mock)
        var iterator = await startAndHandshake(mock, client)

        async let opTask = client.readCertificates(card: "c1")
        let startReq = try #require(await iterator.next())
        guard case .readCertificates = startReq.request else {
            Issue.record("expected ReadCertificates, got \(startReq.request)")
            return
        }
        mock.sendReply(.opStarted(op: 5), req: startReq.req)
        let operation = try await opTask

        mock.sendEvent(.opFinished(op: 5, status: .ok, code: .none, msgKey: "", msgFallback: ""))

        let (status, code, _, msgFallback) = await operation.finished()
        #expect(status == .error)
        #expect(code == .communicationError)
        #expect(!msgFallback.isEmpty)
        #expect(operation.certificatesResult == nil)

        // No recovery twin exists for ReadCertificates — confirm the
        // client never even tried one (Sign is the only kind with a
        // GetSignResult-shaped recovery path).
        #expect(mock.count(of: "GetSignResult") == 0)

        await client.stop()
    }

    @Test("a duplicate OpResultReady closes the previously stored, unclaimed fds instead of leaking them")
    func duplicateOpResultReadyClosesPriorFds() async throws {
        let mock = MockAgentServer()
        let client = makeTestClient(mock: mock)
        var iterator = await startAndHandshake(mock, client)

        async let opTask = client.getPhoto(card: "c1")
        let startReq = try #require(await iterator.next())
        guard case .getPhoto = startReq.request else {
            Issue.record("expected GetPhoto, got \(startReq.request)")
            return
        }
        mock.sendReply(.opStarted(op: 11), req: startReq.req)
        let operation = try await opTask

        // A pipe stands in for a real result fd: closing every writer-side
        // descriptor (including the client's SCM_RIGHTS-received duplicate)
        // is externally observable as EOF on the read end.
        var pipeFds: [Int32] = [0, 0]
        #expect(pipe(&pipeFds) == 0)
        let readEnd = pipeFds[0]
        let writeEnd = pipeFds[1]
        defer { Darwin.close(readEnd) }

        let photo1 = PhotoResult(photos: [PhotoItem(key: "face", fd: 0)])
        mock.sendEvent(.opResultReady(op: 11, result: .photo(photo1)), fds: [writeEnd])

        // A misbehaving server sends a second OpResultReady for the same
        // op before the client ever claims the first result's fd.
        let photo2 = PhotoResult(photos: [])
        mock.sendEvent(.opResultReady(op: 11, result: .photo(photo2)))

        // Synchronize with the actor's frame-processing task: by the time
        // finished() resolves, both events above have been handled.
        mock.sendEvent(.opFinished(op: 11, status: .ok, code: .none, msgKey: "", msgFallback: "done"))
        _ = await operation.finished()
        #expect(operation.result == .photo(photo2))

        let flags = fcntl(readEnd, F_GETFL, 0)
        #expect(fcntl(readEnd, F_SETFL, flags | O_NONBLOCK) == 0)
        var buffer = [UInt8](repeating: 0, count: 1)
        let n = read(readEnd, &buffer, 1)
        #expect(n == 0) // EOF: the first result's fd was closed, not leaked.

        await client.stop()
    }

    // MARK: - Credential operations (gated on the "credentials" feature token)

    @Test("ListCredentials follows the op lifecycle and delivers the credentials payload")
    func listCredentialsLifecycleDeliversPayload() async throws {
        let mock = MockAgentServer()
        let client = makeTestClient(mock: mock)
        var iterator = await startAndHandshake(mock, client, features: ["credentials"])

        async let opTask = client.listCredentials(card: "c1")
        let startReq = try #require(await iterator.next())
        guard case .listCredentials(let card) = startReq.request else {
            Issue.record("expected ListCredentials, got \(startReq.request)")
            return
        }
        #expect(card == "c1")
        mock.sendReply(.opStarted(op: 61), req: startReq.req)
        let operation = try await opTask
        #expect(operation.kind == .listCredentials)

        let listing = CredentialsPayload(
            result: CredentialResult(outcome: .ok, blocked: false),
            records: [
                CredentialRecord(
                    id: "sign:0x92", label: "Signing PIN", kind: .sign, state: .operational,
                    retriesLeft: 3, retriesMax: 3, canChange: true, unblockable: true,
                    unblockStyle: .unblockAndChange, activatable: false, keyActivationPending: false,
                    keyActivatable: false, recovery: .holderViaPuk, probeSafe: true)
            ])
        mock.sendEvent(.opResultReady(op: 61, result: .credentials(listing)))
        mock.sendEvent(.opFinished(op: 61, status: .ok, code: .none, msgKey: "", msgFallback: "listed"))

        let (status, code, _, _) = await operation.finished()
        #expect(status == .ok)
        #expect(code == .none)
        #expect(operation.credentialsResult == listing)
        #expect(operation.result == .credentials(listing))

        await client.stop()
    }

    @Test("ManagePin follows the op lifecycle; the default activateKey=false stays off the wire for verb change")
    func managePinLifecycleDeliversPayload() async throws {
        let mock = MockAgentServer()
        let client = makeTestClient(mock: mock)
        var iterator = await startAndHandshake(mock, client, features: ["credentials"])

        async let opTask = client.managePin(card: "c1", pinId: "user:0x80", verb: .change)
        let startReq = try #require(await iterator.next())
        guard case .managePin(let card, let pinId, let verb, let activateKey) = startReq.request else {
            Issue.record("expected ManagePin, got \(startReq.request)")
            return
        }
        #expect(card == "c1")
        #expect(pinId == "user:0x80")
        #expect(verb == .change)
        // The mock's decoder flattens an ABSENT `activateKey` wire key onto
        // false, so this proves only that the key was not sent as true; the
        // real omission proof is the ManagePin.cbor byte-compare on the Mac.
        #expect(activateKey == false)
        mock.sendReply(.opStarted(op: 62), req: startReq.req)
        let operation = try await opTask
        #expect(operation.kind == .managePin)

        let mutation = CredentialsPayload(
            result: CredentialResult(outcome: .ok, retriesLeft: 3, blocked: false), records: [])
        mock.sendEvent(.opResultReady(op: 62, result: .credentials(mutation)))
        mock.sendEvent(.opFinished(op: 62, status: .ok, code: .none, msgKey: "", msgFallback: "changed"))

        let (status, code, _, _) = await operation.finished()
        #expect(status == .ok)
        #expect(code == .none)
        #expect(operation.credentialsResult == mutation)

        await client.stop()
    }

    @Test("ActivateSigningKey follows the op lifecycle and delivers the credentials payload")
    func activateSigningKeyLifecycleDeliversPayload() async throws {
        let mock = MockAgentServer()
        let client = makeTestClient(mock: mock)
        var iterator = await startAndHandshake(mock, client, features: ["credentials"])

        async let opTask = client.activateSigningKey(card: "c1")
        let startReq = try #require(await iterator.next())
        guard case .activateSigningKey(let card) = startReq.request else {
            Issue.record("expected ActivateSigningKey, got \(startReq.request)")
            return
        }
        #expect(card == "c1")
        mock.sendReply(.opStarted(op: 63), req: startReq.req)
        let operation = try await opTask
        #expect(operation.kind == .activateSigningKey)

        let activation = CredentialsPayload(
            result: CredentialResult(outcome: .ok, blocked: false, pinActivated: true, keyActivated: true),
            records: [])
        mock.sendEvent(.opResultReady(op: 63, result: .credentials(activation)))
        mock.sendEvent(.opFinished(op: 63, status: .ok, code: .none, msgKey: "", msgFallback: "activated"))

        let (status, code, _, _) = await operation.finished()
        #expect(status == .ok)
        #expect(code == .none)
        #expect(operation.credentialsResult == activation)

        await client.stop()
    }

    @Test("a non-Ok OpFinished retains a prior credentials result — the failed-attempt payload stays readable after finished()")
    func nonOkFinishRetainsPriorCredentialsResult() async throws {
        let mock = MockAgentServer()
        let client = makeTestClient(mock: mock)
        var iterator = await startAndHandshake(mock, client, features: ["credentials"])

        async let opTask = client.managePin(card: "c1", pinId: "user:0x80", verb: .change)
        let startReq = try #require(await iterator.next())
        guard case .managePin = startReq.request else {
            Issue.record("expected ManagePin, got \(startReq.request)")
            return
        }
        mock.sendReply(.opStarted(op: 64), req: startReq.req)
        let operation = try await opTask

        // The agent reports the failed attempt as a RESULT (retriesLeft for
        // the UI) and then terminalizes non-Ok — the payload must survive
        // the error finish, not be dropped alongside it.
        let failedAttempt = CredentialsPayload(
            result: CredentialResult(outcome: .invalidPin, retriesLeft: 2, blocked: false), records: [])
        mock.sendEvent(.opResultReady(op: 64, result: .credentials(failedAttempt)))
        mock.sendEvent(
            .opFinished(
                op: 64, status: .error, code: .credentialWrong, msgKey: "credentialWrong",
                msgFallback: "Wrong PIN"))

        let (status, code, msgKey, _) = await operation.finished()
        #expect(status == .error)
        #expect(code == .credentialWrong)
        #expect(msgKey == "credentialWrong")
        #expect(operation.credentialsResult == failedAttempt)

        await client.stop()
    }

    @Test("cancel() emits CancelOp{op}")
    func cancelEmitsCancelOp() async throws {
        let mock = MockAgentServer()
        let client = makeTestClient(mock: mock)
        var iterator = await startAndHandshake(mock, client)

        async let opTask = client.readIdentity(card: "c1")
        let startReq = try #require(await iterator.next())
        mock.sendReply(.opStarted(op: 3), req: startReq.req)
        let operation = try await opTask

        async let cancelTask: Void = operation.cancel()
        let cancelReq = try #require(await iterator.next())
        guard case .cancelOp(let op) = cancelReq.request else {
            Issue.record("expected CancelOp, got \(cancelReq.request)")
            return
        }
        #expect(op == 3)
        mock.sendReply(.ack, req: cancelReq.req)
        await cancelTask

        await client.stop()
    }
}
