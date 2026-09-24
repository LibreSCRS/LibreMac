// SPDX-License-Identifier: LGPL-2.1-or-later
// SPDX-FileCopyrightText: 2026 hirashix0

import Foundation

/// Synchronous, thread-confined request/response over the agent socket for the
/// token extension. ctkd calls the delegate on a bounded thread; the client
/// blocks there for the matching reply, discarding interleaved events. One
/// instance per TKTokenSession; never shared across threads (so it needs no
/// Sendable conformance under strict concurrency).
public protocol TokenTransport {
    func send(_ request: AgentRequest) throws -> AgentReply
}

/// `notDelivered` is kept apart from `ioFailed` because it answers the one
/// question a reconnect has to ask: the request's frame never left this
/// process whole, so the agent — which dispatches only complete frames — never
/// acted on it. `ioFailed` and `closed` arrive after the whole frame was
/// written, when the agent may already be acting on it. `timedOut` is the I/O
/// deadline expiring: the agent is still there but not answering, which a new
/// connection to the same process does not fix. `peerRejected` is a connection
/// whose serving process failed the identity check: nothing was sent, and
/// connecting again reaches the same process.
public enum TokenTransportError: Error, Equatable {
    case connectFailed, ioFailed, decodeFailed, closed, notDelivered, timedOut, peerRejected
}

/// Platform-neutral error the extension turns into a TKError (keeps the package CTK-free).
///
/// `canceledByUser` is the one member that is not a failure: it is the person
/// answering the prompt with "no". It is carried separately because the
/// alternative — folding it into `communicationError` — reports a dismissed
/// PIN prompt as a device failure, which is a different claim about the reader
/// and the card than the one the person actually made.
public enum TKErrorMapped: Sendable, Equatable {
    case tokenNotFound, authenticationFailed, objectNotFound
    case authenticationNeeded, communicationError, notImplemented
    case canceledByUser
}
public enum TokenOpError: Error, Equatable { case mapped(TKErrorMapped) }
