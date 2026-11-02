// SPDX-License-Identifier: LGPL-2.1-or-later
// SPDX-FileCopyrightText: 2026 hirashix0
//
// A reader's display label, from the label the agent sends with it. The agent
// reads the PC/SC name once, over the whole roster -- the model, which
// interface a dual-interface slot is, a twin told apart -- so this host only
// words it in the user's language and never parses the name itself. The
// contact/contactless formatters are injected so this file carries no
// localization state. Selection always uses the raw reader handle; only
// DISPLAY uses these labels.

import LibreMacAgentClient

/// The label shown for `reader`: its model, with the interface worded for the
/// slots of a dual-interface unit. An agent that sends no label leaves the
/// PC/SC name, unparsed.
func readerDisplayLabel(
    _ reader: ReaderState,
    contact: (_ model: String) -> String,
    contactless: (_ model: String) -> String
) -> String {
    guard let model = reader.model else { return reader.name }
    switch reader.interface {
    case .contact: return contact(model)
    case .contactless: return contactless(model)
    case .unknown: return model
    }
}
