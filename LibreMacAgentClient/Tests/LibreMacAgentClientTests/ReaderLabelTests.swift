// SPDX-License-Identifier: LGPL-2.1-or-later
// SPDX-FileCopyrightText: 2026 hirashix0

import Foundation
import Testing
@testable import LibreMacAgentClient

// The reader's label (`reader-state.model` / `.interface`) is the agent's one
// reading of the PC/SC name; a client shows it and never parses the name. These
// hold the decode to the contract's tolerance rules and the registry to the
// relabel event the agent sends when a neighbour arrives or leaves.

private func cborMap(_ pairs: [(String, CBORValue)]) -> CBORValue {
    .map(pairs.map { (Data($0.0.utf8), $0.1) })
}

private func readerAdded(_ reader: [(String, CBORValue)]) throws -> AgentEvent {
    let event = cborMap([("t", .text("ReaderAdded")), ("reader", cborMap(reader))])
    return try AgentMessages.decodeEvent(event.encode())
}

private let bareReader: [(String, CBORValue)] = [
    ("handle", .text("r2")), ("name", .text("HID Global OMNIKEY 5422 Smartcard Reader 01 00")),
    ("hasCard", .bool(false)),
]

@Suite("Reader label on the wire")
struct ReaderLabelTests {

    @Test("model and interface decode into the reader")
    func labelDecodes() throws {
        let ev = try readerAdded(
            bareReader + [("model", .text("OMNIKEY 5422")), ("interface", .text("contactless"))])
        guard case .readerAdded(let reader) = ev else {
            Issue.record("expected ReaderAdded, got \(ev)")
            return
        }
        #expect(reader.model == "OMNIKEY 5422")
        #expect(reader.interface == .contactless)
    }

    @Test("a reader without a label decodes with none: an older agent is not a failure")
    func absentLabelIsNone() throws {
        guard case .readerAdded(let reader) = try readerAdded(bareReader) else {
            Issue.record("expected ReaderAdded")
            return
        }
        #expect(reader.model == nil)
        #expect(reader.interface == .unknown)
    }

    @Test("an empty model is no label")
    func emptyModelIsNone() throws {
        guard case .readerAdded(let reader) = try readerAdded(
            bareReader + [("model", .text("")), ("interface", .text("contact"))])
        else {
            Issue.record("expected ReaderAdded")
            return
        }
        #expect(reader.model == nil)
    }

    @Test("an interface token this client does not know decodes as unknown, not as an error")
    func unknownInterfaceToken() throws {
        guard case .readerAdded(let reader) = try readerAdded(
            bareReader + [("model", .text("OMNIKEY 5422")), ("interface", .text("magnetic-stripe"))])
        else {
            Issue.record("expected ReaderAdded")
            return
        }
        #expect(reader.model == "OMNIKEY 5422")
        #expect(reader.interface == .unknown)
    }

    @Test("a model that is not text is a malformed reader")
    func wrongModelType() {
        #expect(throws: MessageError.self) {
            try readerAdded(bareReader + [("model", .uint(5422))])
        }
    }

    @Test("a Reader1 PropertyChanged relabels the reader and publishes a snapshot")
    func relabelEvent() async {
        let mock = MockAgentServer()
        let client = makeTestClient(mock: mock)
        let reader = ReaderState(
            handle: "r1", name: "HID Global OMNIKEY 5422 Smartcard Reader 00 00", hasCard: true, card: "c1",
            model: "OMNIKEY 5422", interface: .unknown)
        _ = await startAndHandshake(mock, client, readers: [reader])

        var snapshots = client.registryUpdates.makeAsyncIterator()
        let seeded = await snapshots.next()
        #expect(seeded?.readers == [reader])

        // Another interface's change, and a Reader1 change without a label,
        // leave the label alone and publish nothing.
        mock.sendEvent(
            .propertyChanged(
                handle: "r1", iface: "org.librescrs.Agent.Card1", props: ["Model": .text("not a reader")]))
        mock.sendEvent(
            .propertyChanged(
                handle: "r1", iface: "org.librescrs.Agent.Reader1", props: ["HasCard": .bool(true)]))
        // A contactless sibling arrived: the agent relabels this slot.
        mock.sendEvent(
            .propertyChanged(
                handle: "r1", iface: "org.librescrs.Agent.Reader1",
                props: ["Model": .text("OMNIKEY 5422"), "Interface": .text("contact")]))
        // A fence that always publishes: a client that ignored the relabel
        // shows the old label here instead of waiting forever.
        mock.sendEvent(.readerAdded(ReaderState(handle: "r9", name: "fence", hasCard: false)))

        let next = await snapshots.next()
        #expect(next?.readers.first { $0.handle == "r1" }
                == reader.relabelled(model: "OMNIKEY 5422", interface: .contact))
        let readers = await client.readers()
        #expect(readers.first { $0.handle == "r1" }?.interface == .contact)

        await client.stop()
    }

    @Test("a relabel naming only the interface keeps the model it already had")
    func interfaceOnlyRelabel() async {
        let mock = MockAgentServer()
        let client = makeTestClient(mock: mock)
        let reader = ReaderState(
            handle: "r1", name: "HID Global OMNIKEY 5422 Smartcard Reader 01 00", hasCard: false,
            model: "OMNIKEY 5422", interface: .unknown)
        _ = await startAndHandshake(mock, client, readers: [reader])

        var snapshots = client.registryUpdates.makeAsyncIterator()
        let seeded = await snapshots.next()
        #expect(seeded?.readers == [reader])

        // Each label key is optional in the contract: one sent alone is
        // still a relabel, applied over the other's current value.
        mock.sendEvent(
            .propertyChanged(
                handle: "r1", iface: "org.librescrs.Agent.Reader1",
                props: ["Interface": .text("contactless")]))
        // Fence, as above: a client that dropped the relabel shows the old
        // label in this snapshot.
        mock.sendEvent(.readerAdded(ReaderState(handle: "r9", name: "fence", hasCard: false)))

        let next = await snapshots.next()
        #expect(next?.readers.first { $0.handle == "r1" }
                == reader.relabelled(model: "OMNIKEY 5422", interface: .contactless))

        await client.stop()
    }
}
