// SPDX-License-Identifier: LGPL-2.1-or-later
// SPDX-FileCopyrightText: 2026 hirashix0

import Foundation

/// How long a single request's prompt chain may run, vendored from the
/// agent rather than computed locally: neither socket client can derive it,
/// because the wire carries no deadline field (a deadline is not a wire
/// vocabulary term -- see `WireVocabularyConformanceTests`), and the agent
/// is the only side that knows how many prompts one request can chain (CAN
/// entry followed by a PIN change, for example).
///
/// `maxSequential` is the sum a request's prompts may add up to, not any
/// one prompt's deadline. `PromptBudgetContractTests` pins the value
/// against `Contract/prompt-policy.txt`, using the same vendor-and-pin
/// mechanism as the wire vocabulary contract (`Contract/prompt-policy.provenance`
/// names the agent commit the number was read from). Today that number
/// equals the agent's single longest deadline, because the agent has not
/// yet declared a dedicated sequential-chain constant -- see the
/// provenance file for the detail.
public enum PromptBudget {
    /// Seconds.
    public static let maxSequential: TimeInterval = 300
}
