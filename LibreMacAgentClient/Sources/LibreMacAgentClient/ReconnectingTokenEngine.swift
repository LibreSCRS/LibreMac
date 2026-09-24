// SPDX-License-Identifier: LGPL-2.1-or-later
// SPDX-FileCopyrightText: 2026 hirashix0

import Foundation

/// The token extension's agent connection, rebuilt when the agent closed it.
///
/// ctkd keeps a `TKTokenSession` for as long as the token is registered, so a
/// connection the agent closed (restart, queue backstop) would otherwise fail
/// every later operation of that session. `withEngine` drops a connection that
/// failed and, when replaying the operation is safe, runs it once more over a
/// fresh one. A second failure answers `communicationError`; there is no loop.
///
/// Replay is safe only while nothing that can prompt or use the key has reached
/// the agent in this attempt. The agent runs `Pkcs11.Login` and
/// `Pkcs11.SignRaw` to completion whether or not the connection that asked is
/// still open (the reply is simply dropped), and those are the calls that raise
/// the CAN/PIN prompt and produce a signature. Replaying one would prompt the
/// person again and sign twice. So only `GetState`, `GetCertDer` and
/// `Pkcs11.PublicKey` may have been delivered before the failure; any other
/// request counts once its frame was written whole, answered or not. Every
/// operation starts with `GetState`, which is what meets a connection the agent
/// closed while idle, so that case is always rebuilt.
///
/// Thread-confined like `TokenTransport`: one instance per session, called on
/// ctkd's thread for that session.
public final class ReconnectingTokenEngine {
    private let connect: () throws -> TokenTransport
    private var transport: TokenTransport?

    /// `connect` opens a new agent connection; it is called lazily, on the
    /// first operation and again after a connection failed.
    public init(connect: @escaping () throws -> TokenTransport) {
        self.connect = connect
    }

    /// Runs `operation` over the current connection. Errors other than the
    /// transport's pass through unchanged; transport failures surface as
    /// `TokenOpError.mapped(.communicationError)`.
    public func withEngine<T>(_ operation: (TokenOpEngine) throws -> T) throws -> T {
        let first = try attempt(operation)
        switch first {
        case .done(let value):
            return value
        case .failed(let replayable):
            guard replayable else { throw TokenOpError.mapped(.communicationError) }
        }
        switch try attempt(operation) {
        case .done(let value):
            return value
        case .failed:
            throw TokenOpError.mapped(.communicationError)
        }
    }

    private enum Outcome<T> {
        case done(T)
        case failed(replayable: Bool)
    }

    /// One try. On a transport failure the connection is released before this
    /// returns, so its fd is closed before any replacement is opened — the
    /// agent discards a partly written frame only when the connection ends.
    private func attempt<T>(_ operation: (TokenOpEngine) throws -> T) throws -> Outcome<T> {
        let current: TokenTransport
        if let transport {
            current = transport
        } else {
            do {
                current = try connect()
            } catch {
                throw TokenOpError.mapped(.communicationError)
            }
            transport = current
        }
        let tracked = DeliveryTracker(current)
        do {
            return .done(try operation(TokenOpEngine(transport: tracked)))
        } catch {
            // The engine swallows a failed `GetCertDer` probe (`try?`) and may
            // answer tokenNotFound over a connection that is already dead, so
            // the tracker, not the error that surfaced, says whether it failed.
            guard let failure = tracked.failure else { throw error }
            transport = nil
            // decodeFailed means the reply stream is corrupt: what the agent
            // did with the request is unknown, so it is never replayed.
            let replayable = failure != .decodeFailed && !tracked.consequentialRequestDelivered
            return .failed(replayable: replayable)
        }
    }
}

/// Records the first transport failure of an attempt and whether a request
/// with an effect beyond reading reached the agent.
private final class DeliveryTracker: TokenTransport {
    private let inner: TokenTransport
    private(set) var consequentialRequestDelivered = false
    private(set) var failure: TokenTransportError?

    init(_ inner: TokenTransport) {
        self.inner = inner
    }

    func send(_ request: AgentRequest) throws -> AgentReply {
        do {
            let reply = try inner.send(request)
            note(request)
            return reply
        } catch let error as TokenTransportError {
            if failure == nil { failure = error }
            if error != .notDelivered { note(request) }
            throw error
        }
    }

    private func note(_ request: AgentRequest) {
        if !Self.isRead(request) { consequentialRequestDelivered = true }
    }

    /// Requests the agent answers from state without prompting or touching a
    /// key. Anything not listed — including requests added later — counts as
    /// consequential, so the default is the safe one.
    private static func isRead(_ request: AgentRequest) -> Bool {
        switch request {
        case .getState, .getCertDer, .pkPublicKey: return true
        default: return false
        }
    }
}
