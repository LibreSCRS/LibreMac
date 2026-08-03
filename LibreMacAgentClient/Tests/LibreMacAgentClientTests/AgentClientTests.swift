// SPDX-License-Identifier: LGPL-2.1-or-later
// SPDX-FileCopyrightText: 2026 hirashix0

import Foundation
import Testing
@testable import LibreMacAgentClient

@Suite("AgentClient")
struct AgentClientTests {

    // MARK: - Hello-first + HelloAck

    @Test("connects, sends Hello first, and HelloAck populates agent version/features")
    func helloFirstPopulatesAgentInfo() async {
        let mock = MockAgentServer()
        let client = makeTestClient(mock: mock)
        _ = await startAndHandshake(mock, client, readers: [], cards: [])

        var availabilityIterator = client.availability.makeAsyncIterator()
        let available = await availabilityIterator.next()
        #expect(available == true)

        // The handshake in `startAndHandshake` answers with the default
        // test agent version/features baked into `answerHandshake`.
        let info = await client.agentInfo()
        #expect(info.version == "1.0.0-test")
        #expect(info.features == [])

        await client.stop()
    }

    @Test("Hello is the very first request on a fresh connection")
    func helloIsFirstRequest() async throws {
        let mock = MockAgentServer()
        let client = makeTestClient(mock: mock)
        await client.start()

        var iterator = mock.requests.makeAsyncIterator()
        let first = try #require(await iterator.next())
        guard case .hello(let proto, let clientName) = first.request else {
            Issue.record("expected the first request to be Hello, got \(first.request)")
            return
        }
        #expect(proto == 1)
        #expect(clientName?.hasPrefix("LibreMac/") == true)
        mock.sendReply(.helloAck(agentVer: "1.0", features: []), req: first.req)
        let second = try #require(await iterator.next())
        guard case .getState = second.request else {
            Issue.record("expected the second request to be GetState, got \(second.request)")
            return
        }

        await client.stop()
    }

    // MARK: - Request/reply correlation with interleaved events

    @Test("interleaved unsolicited events don't desync request/reply correlation")
    func interleavedEventsDontDesyncCorrelation() async throws {
        let mock = MockAgentServer()
        let client = makeTestClient(mock: mock)
        var iterator = await startAndHandshake(mock, client)

        async let configTask = client.getConfig()

        let configReq = try #require(await iterator.next())
        guard case .getConfig = configReq.request else {
            Issue.record("expected GetConfig, got \(configReq.request)")
            return
        }

        // Unsolicited events ride the same stream, ahead of the reply —
        // the client must skip them without losing correlation.
        mock.sendEvent(.readerAdded(ReaderState(handle: "r1", name: "Reader 1", hasCard: false)))
        mock.sendEvent(.cardAdded(CardState(handle: "c1", reader: "r1", caps: [], preAuth: .none)))
        mock.sendEvent(.readerAdded(ReaderState(handle: "r2", name: "Reader 2", hasCard: false)))

        mock.sendReply(.config(entries: ["tsaUrl": .text("https://tsa.example")]), req: configReq.req)

        let entries = try await configTask
        #expect(entries["tsaUrl"] == .text("https://tsa.example"))

        // The interleaved events were still processed (registry updated), not
        // merely swallowed. Every event is applied as its frame is dispatched,
        // and these three were dispatched ahead of the reply just awaited —
        // so they have already landed, with no waiting of any kind.
        let readers = await client.readers()
        #expect(Set(readers.map(\.handle)) == Set(["r1", "r2"]))

        await client.stop()
    }

    @Test("the GetState snapshot never discards events that arrived behind it on the wire")
    func stateSnapshotDoesNotClobberLaterEvents() async throws {
        // The agent may emit ReaderAdded the instant after it answers
        // GetState. The reply and the event are then adjacent on the wire,
        // in that order, and the registry must end up reflecting BOTH — the
        // snapshot first, the event on top of it.
        //
        // Whether that holds is a scheduling question, so one pass proves
        // little: repeat, and let the odds do the work. Each pass is a fresh
        // client over a fresh socketpair.
        for pass in 0..<40 {
            let mock = MockAgentServer()
            let client = makeTestClient(mock: mock)
            await client.start()
            var iterator = mock.requests.makeAsyncIterator()

            let hello = try #require(await iterator.next())
            mock.sendReply(.helloAck(agentVer: "1.0.0-test", features: []), req: hello.req)

            let getState = try #require(await iterator.next())
            guard case .getState = getState.request else {
                Issue.record("expected GetState second, got \(getState.request)")
                return
            }
            // Empty snapshot, then the event immediately behind it — the
            // tightest window there is between the two.
            mock.sendReply(.state(readers: [], cards: []), req: getState.req)
            mock.sendEvent(.readerAdded(ReaderState(handle: "r1", name: "Reader 1", hasCard: false)))

            // A round trip that must be dispatched after the event: once its
            // reply resolves, the event ahead of it has already been applied.
            // No polling — wire order is the property under test, and a poll
            // would paper over losing it.
            async let configTask = client.getConfig()
            let configReq = try #require(await iterator.next())
            mock.sendReply(.config(entries: [:]), req: configReq.req)
            _ = try await configTask

            let readers = await client.readers()
            #expect(readers.map(\.handle) == ["r1"], "pass \(pass): the snapshot overwrote the event behind it")

            await client.stop()
        }
    }

    // MARK: - Registry population + mutation + snapshot stream

    @Test("GetState populates the registry; ReaderAdded/CardAdded/CardRemoved mutate it and publish a snapshot each time")
    func registryMutatesAndPublishesSnapshots() async {
        let mock = MockAgentServer()
        let client = makeTestClient(mock: mock)
        let initialReader = ReaderState(handle: "r1", name: "Reader 1", hasCard: false)
        _ = await startAndHandshake(mock, client, readers: [initialReader])

        var snapshots = client.registryUpdates.makeAsyncIterator()
        let firstSnapshot = await snapshots.next()
        #expect(firstSnapshot?.readers == [initialReader])
        #expect(firstSnapshot?.cards.isEmpty == true)

        let card = CardState(handle: "c1", reader: "r1", caps: [.pki], preAuth: .none)
        mock.sendEvent(.cardAdded(card))
        let afterCardAdded = await snapshots.next()
        #expect(afterCardAdded?.cards == [card])

        mock.sendEvent(.cardRemoved(handle: "c1"))
        let afterCardRemoved = await snapshots.next()
        #expect(afterCardRemoved?.cards.isEmpty == true)

        let reader2 = ReaderState(handle: "r2", name: "Reader 2", hasCard: false)
        mock.sendEvent(.readerAdded(reader2))
        let afterReaderAdded = await snapshots.next()
        #expect(Set(afterReaderAdded?.readers.map(\.handle) ?? []) == Set(["r1", "r2"]))

        mock.sendEvent(.readerRemoved(handle: "r1"))
        let afterReaderRemoved = await snapshots.next()
        #expect(afterReaderRemoved?.readers.map(\.handle) == ["r2"])

        let readers = await client.readers()
        #expect(readers.map(\.handle) == ["r2"])

        await client.stop()
    }

    // MARK: - Method-entry timeout

    @Test("a request with no reply within propTimeout throws .timeout")
    func methodEntryTimeout() async {
        let mock = MockAgentServer()
        let client = makeTestClient(mock: mock, propTimeout: 0.2)
        _ = await startAndHandshake(mock, client)

        do {
            _ = try await client.getConfig()
            Issue.record("expected .timeout")
        } catch {
            #expect((error as? AgentClientError) == .timeout)
        }

        await client.stop()
    }

    // MARK: - Death sweep — the step ordering is the contract

    @Test("death sweep: the live operation finishes vanished strictly before the registry clears and availability publishes false")
    func deathSweepOrdering() async throws {
        let mock = MockAgentServer()
        let client = makeTestClient(mock: mock)
        let reader = ReaderState(handle: "r1", name: "Reader 1", hasCard: true, card: "c1")
        let card = CardState(handle: "c1", reader: "r1", caps: [.identityData], preAuth: .none)
        var iterator = await startAndHandshake(mock, client, readers: [reader], cards: [card])

        async let opTask = client.readIdentity(card: "c1")
        let startReq = try #require(await iterator.next())
        guard case .readIdentity = startReq.request else {
            Issue.record("expected ReadIdentity, got \(startReq.request)")
            return
        }
        mock.sendReply(.opStarted(op: 1), req: startReq.req)
        let operation = try await opTask

        let readersBefore = await client.readers()
        #expect(!readersBefore.isEmpty)
        #expect(await client.isAvailable())

        // Subscribe to both publication streams BEFORE the drop. Each
        // stream buffers from its own creation, so the first values are
        // the handshake-time ones; drain those first.
        var snapshots = client.registryUpdates.makeAsyncIterator()
        let populatedSnapshot = await snapshots.next()
        #expect(populatedSnapshot?.readers.isEmpty == false)
        var availabilityIterator = client.availability.makeAsyncIterator()
        let initiallyAvailable = await availabilityIterator.next()
        #expect(initiallyAvailable == true)
        #expect(!operation.isFinished)

        mock.dropConnection()

        // THE death-sweep ordering contract, asserted observably: the sweep
        // resolves the operation's `finished` BEFORE it yields the
        // cleared-registry snapshot, and BEFORE it publishes
        // available=false. AsyncStream delivery preserves yield order, so
        // if `finished` had not yet fired when either publication was
        // made, `isFinished` would be false here and the test would fail.
        let clearedSnapshot = await snapshots.next()
        #expect(clearedSnapshot?.readers.isEmpty == true)
        #expect(clearedSnapshot?.cards.isEmpty == true)
        #expect(operation.isFinished, "the op must terminalize BEFORE the registry-clear snapshot publishes")

        let unavailable = await availabilityIterator.next()
        #expect(unavailable == false)
        #expect(operation.isFinished, "the op must terminalize BEFORE available=false publishes")

        let (status, code, msgKey, msgFallback) = await operation.finished()
        #expect(status == .cancelled)
        #expect(code == .communicationError)
        #expect(msgKey == AgentClient.vanishedMsgKey)

        // `finished()` resolves exactly once: a second await returns the
        // same terminal tuple rather than hanging or changing.
        let secondFinished = await operation.finished()
        #expect(secondFinished == (status, code, msgKey, msgFallback))

        let readersAfter = await client.readers()
        let cardsAfter = await client.cards()
        #expect(readersAfter.isEmpty)
        #expect(cardsAfter.isEmpty)
        #expect(await client.isAvailable() == false)

        await client.stop()
    }

    @Test("availability publishes false after a drop and true again after reconnecting")
    func availabilityStreamReflectsDropAndReconnect() async {
        let mock = MockAgentServer()
        let client = makeTestClient(mock: mock)
        var iterator = await startAndHandshake(mock, client)

        var availabilityIterator = client.availability.makeAsyncIterator()
        let first = await availabilityIterator.next()
        #expect(first == true)

        mock.dropConnection()
        let afterDrop = await availabilityIterator.next()
        #expect(afterDrop == false)

        await answerHandshake(mock, &iterator)
        let afterReconnect = await availabilityIterator.next()
        #expect(afterReconnect == true)

        await client.stop()
    }

    // MARK: - Reconnect backoff

    @Test("reconnects with capped exponential backoff after the agent restarts")
    func reconnectsAfterRestartWithBackoff() async {
        let mock = MockAgentServer()
        let client = makeTestClient(mock: mock, initialBackoff: 0.05, maxBackoff: 0.1)
        var iterator = await startAndHandshake(mock, client)

        var availabilityIterator = client.availability.makeAsyncIterator()
        let firstAvailable = await availabilityIterator.next()
        #expect(firstAvailable == true)

        // Simulate the agent process crashing: connections are dropped and
        // new connect attempts fail until `restart()`.
        mock.stop()
        let becameUnavailable = await availabilityIterator.next()
        #expect(becameUnavailable == false)

        mock.restart()
        // The supervisor keeps retrying on the capped backoff; once a
        // connect attempt lands, it re-does the full Hello/GetState
        // handshake exactly like the first connection (Hello always first).
        // This first post-connect retry MUST use the injected
        // `initialBackoff` (0.05s here), not the class-default 1.0s — the
        // wait below (real awaits, not a fixed sleep) bounds the elapsed
        // time well under 1.0s to catch a regression where the reset
        // silently falls back to the hardcoded default.
        let reconnectStart = Date()
        await answerHandshake(mock, &iterator)

        let reconnected = await availabilityIterator.next()
        #expect(reconnected == true)

        let elapsed = Date().timeIntervalSince(reconnectStart)
        #expect(
            elapsed < 0.5,
            "reconnect took \(elapsed)s — expected the injected initialBackoff (0.05s) to govern the wait, not the hardcoded 1.0s default"
        )

        await client.stop()
    }

    // MARK: - Direct (non-Operation1) request/reply calls

    @Test("certificateDer() sends GetCertDer and returns the inline DER bytes")
    func certificateDerReturnsInlineBytes() async throws {
        let mock = MockAgentServer()
        let client = makeTestClient(mock: mock)
        var iterator = await startAndHandshake(mock, client)

        async let derTask = client.certificateDer(reader: "r1", certId: "cert1")
        let request = try #require(await iterator.next())
        guard case .getCertDer(let reader, let cert) = request.request else {
            Issue.record("expected GetCertDer, got \(request.request)")
            return
        }
        #expect(reader == "r1")
        #expect(cert == "cert1")
        mock.sendReply(.certDer(der: Data([0x30, 0x82, 0x01])), req: request.req)

        let der = try await derTask
        #expect(der == Data([0x30, 0x82, 0x01]))

        await client.stop()
    }

    @Test("a server err reply surfaces as AgentClientError.serverError")
    func serverErrSurfacesAsServerError() async throws {
        let mock = MockAgentServer()
        let client = makeTestClient(mock: mock)
        var iterator = await startAndHandshake(mock, client)

        async let derTask = client.certificateDer(reader: "r1", certId: "missing")
        let request = try #require(await iterator.next())
        mock.sendReply(.err(ErrInfo(code: .code(.keyNotFound))), req: request.req)

        do {
            _ = try await derTask
            Issue.record("expected serverError")
        } catch AgentClientError.serverError(let info) {
            #expect(info.code == .code(.keyNotFound))
        }

        await client.stop()
    }

    // MARK: - Credential ops — HelloAck feature gating

    @Test("without the credentials feature token, all three credential ops throw .notSupported and never send")
    func credentialOpsWithoutFeatureTokenThrowNotSupported() async {
        let mock = MockAgentServer()
        let client = makeTestClient(mock: mock)
        // Default handshake features: [] — no "credentials" token.
        _ = await startAndHandshake(mock, client)

        #expect(await client.supportsCredentials == false)

        do {
            _ = try await client.listCredentials(card: "c1")
            Issue.record("expected .notSupported from listCredentials")
        } catch AgentClientError.notSupported {
            // Expected.
        } catch {
            Issue.record("expected .notSupported from listCredentials, got \(error)")
        }
        do {
            _ = try await client.managePin(card: "c1", pinId: "sign:0x92", verb: .change)
            Issue.record("expected .notSupported from managePin")
        } catch AgentClientError.notSupported {
            // Expected.
        } catch {
            Issue.record("expected .notSupported from managePin, got \(error)")
        }
        do {
            _ = try await client.activateSigningKey(card: "c1")
            Issue.record("expected .notSupported from activateSigningKey")
        } catch AgentClientError.notSupported {
            // Expected.
        } catch {
            Issue.record("expected .notSupported from activateSigningKey, got \(error)")
        }

        // The gate is strictly client-side: an old agent fails an unknown
        // request `t` closed and DROPS the connection, so none of the
        // three requests may ever reach the wire.
        #expect(mock.count(of: "ListCredentials") == 0)
        #expect(mock.count(of: "ManagePin") == 0)
        #expect(mock.count(of: "ActivateSigningKey") == 0)

        await client.stop()
    }

    @Test("on a never-started client, credential ops throw .notConnected — not .notSupported — despite the empty feature set")
    func credentialOpsOnUnstartedClientThrowNotConnected() async {
        let mock = MockAgentServer()
        let client = makeTestClient(mock: mock)
        // Never started: no connection, so the feature set is empty too —
        // but the connection guard must win over the feature gate, or a
        // merely disconnected client would misreport as "agent too old".
        #expect(await client.supportsCredentials == false)

        do {
            _ = try await client.listCredentials(card: "c1")
            Issue.record("expected .notConnected from listCredentials")
        } catch AgentClientError.notConnected {
            // Expected.
        } catch {
            Issue.record("expected .notConnected from listCredentials, got \(error)")
        }
        do {
            _ = try await client.managePin(card: "c1", pinId: "sign:0x92", verb: .change)
            Issue.record("expected .notConnected from managePin")
        } catch AgentClientError.notConnected {
            // Expected.
        } catch {
            Issue.record("expected .notConnected from managePin, got \(error)")
        }

        await client.stop()
    }

    @Test("with the credentials feature token, listCredentials sends ListCredentials")
    func listCredentialsSendsWhenFeatureTokenPresent() async throws {
        let mock = MockAgentServer()
        let client = makeTestClient(mock: mock)
        var iterator = await startAndHandshake(mock, client, features: ["credentials"])

        #expect(await client.supportsCredentials == true)

        async let opTask = client.listCredentials(card: "c1")
        let request = try #require(await iterator.next())
        guard case .listCredentials(let card) = request.request else {
            Issue.record("expected ListCredentials, got \(request.request)")
            return
        }
        #expect(card == "c1")
        mock.sendReply(.opStarted(op: 30), req: request.req)
        let operation = try await opTask
        #expect(operation.kind == .listCredentials)

        await client.stop()
    }
}
