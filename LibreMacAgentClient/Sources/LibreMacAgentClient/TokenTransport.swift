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

public enum TokenTransportError: Error, Equatable {
    case connectFailed, ioFailed, decodeFailed, closed
}

/// Platform-neutral error the extension turns into a TKError (keeps the package CTK-free).
public enum TKErrorMapped: Sendable, Equatable {
    case tokenNotFound, authenticationFailed, objectNotFound
    case authenticationNeeded, communicationError, notImplemented
}
public enum TokenOpError: Error, Equatable { case mapped(TKErrorMapped) }
