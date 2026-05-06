// SPDX-License-Identifier: LGPL-2.1-or-later
// SPDX-FileCopyrightText: 2026 hirashix0
//
// CardSession lifecycle + PKI operations across the C ABI.
//
// Plumbing notes:
// - lm_session_t carries the open CardSession together with the matched
//   CardPlugin (selected via the registry's two-phase canHandle / canHandleConnection
//   probe at open time). Holding the plugin handle here means subsequent
//   verify_pin / sign calls do not need to re-probe.
// - All Secure::String construction stays inside the bridge: the caller's
//   `const char*` PIN buffer is copied once into a Secure::String that
//   cleanses on scope exit (LM Secure::String uses a secure_allocator
//   per LibreMiddleware feedback_b0e4855).

#include "bridge.h"

#include <LibreSCRS/Plugin/CardPlugin.h>
#include <LibreSCRS/Plugin/CardPluginService.h>
#include <LibreSCRS/Plugin/PluginTypes.h>
#include <LibreSCRS/Plugin/ReadResult.h>
#include <LibreSCRS/Secure/String.h>
#include <LibreSCRS/SmartCard/CardSession.h>

#include <cstdlib>
#include <cstring>
#include <memory>
#include <new>
#include <span>
#include <string>
#include <string_view>
#include <utility>
#include <variant>

#include "registry_handle.h"

namespace {

struct SessionHandle {
    LibreSCRS::SmartCard::CardSession session;
    std::shared_ptr<LibreSCRS::Plugin::CardPlugin> plugin;

    SessionHandle(LibreSCRS::SmartCard::CardSession s,
                  std::shared_ptr<LibreSCRS::Plugin::CardPlugin> p) noexcept
        : session(std::move(s)), plugin(std::move(p))
    {}
};

char* duplicateAsCString(std::string_view s) noexcept
{
    auto* out = static_cast<char*>(std::malloc(s.size() + 1));
    if (out == nullptr) {
        return nullptr;
    }
    std::memcpy(out, s.data(), s.size());
    out[s.size()] = '\0';
    return out;
}

lm_open_status_t mapOpenKind(LibreSCRS::SmartCard::OpenError::Kind k) noexcept
{
    using K = LibreSCRS::SmartCard::OpenError::Kind;
    switch (k) {
        case K::ReaderUnavailable: return LM_OPEN_READER_UNAVAILABLE;
        case K::NoCardPresent:     return LM_OPEN_NO_CARD;
        case K::ProtocolError:     return LM_OPEN_PROTOCOL_ERROR;
    }
    return LM_OPEN_READER_UNAVAILABLE;
}

LibreSCRS::Plugin::SignMechanism mapSignMechanism(lm_sign_mechanism_t m) noexcept
{
    using SM = LibreSCRS::Plugin::SignMechanism;
    switch (m) {
        case LM_MECH_RSA_PKCS:     return SM::RSA_PKCS;
        case LM_MECH_ECDSA_SHA256: return SM::ECDSA_SHA256;
        case LM_MECH_ECDSA_SHA384: return SM::ECDSA_SHA384;
        case LM_MECH_ECDSA_SHA512: return SM::ECDSA_SHA512;
    }
    return SM::RSA_PKCS;
}

} // namespace

extern "C" {

lm_session_t lm_session_open(lm_registry_t r,
                             const char* reader_name,
                             lm_open_status_t* out_status,
                             char** out_error_message)
{
    if (r == nullptr || reader_name == nullptr) {
        if (out_status != nullptr) {
            *out_status = LM_OPEN_READER_UNAVAILABLE;
        }
        if (out_error_message != nullptr) {
            *out_error_message = duplicateAsCString("null registry or reader name");
        }
        return nullptr;
    }

    // CardSession::open returns std::expected<CardSession, OpenError>.
    auto opened = LibreSCRS::SmartCard::CardSession::open(std::string{reader_name});
    if (!opened) {
        const auto& err = opened.error();
        if (out_status != nullptr) {
            *out_status = mapOpenKind(err.kind);
        }
        if (out_error_message != nullptr) {
            // Prefer diagnosticDetail (developer-facing, actionable) when
            // present; fall back to the user-facing defaultText. The bridge
            // does not sanitise here — the LM contract documents that
            // diagnosticDetail never carries secret material.
            const auto& msg = err.diagnosticDetail.has_value()
                                  ? *err.diagnosticDetail
                                  : err.userMessage.defaultText;
            *out_error_message = duplicateAsCString(msg);
        }
        return nullptr;
    }

    // Two-phase candidate match: ATR first, then AID probe on live session.
    auto& session = *opened;
    auto candidates = r->registry.findAllCandidates(session.atr(), session);
    if (candidates.empty()) {
        if (out_status != nullptr) {
            *out_status = LM_OPEN_NO_MATCHING_PLUGIN;
        }
        if (out_error_message != nullptr) {
            *out_error_message = duplicateAsCString("No plugin recognised this card");
        }
        return nullptr;
    }

    if (out_status != nullptr) {
        *out_status = LM_OPEN_OK;
    }
    return reinterpret_cast<lm_session_t>(
        new (std::nothrow) SessionHandle(std::move(session), std::move(candidates.front())));
}

void lm_session_close(lm_session_t s)
{
    delete reinterpret_cast<SessionHandle*>(s);
}

lm_read_status_t lm_session_read_certificates(lm_session_t s,
                                              lm_buffer_t** out_certs,
                                              size_t* out_count,
                                              char** out_error_message)
{
    auto* h = reinterpret_cast<SessionHandle*>(s);
    if (h == nullptr || out_certs == nullptr || out_count == nullptr) {
        return LM_READ_COMM_ERROR;
    }
    try {
        auto certs = h->plugin->readCertificates(h->session);
        if (certs.empty()) {
            *out_certs = nullptr;
            *out_count = 0;
            return LM_READ_OK;
        }
        auto* arr = static_cast<lm_buffer_t*>(std::calloc(certs.size(), sizeof(lm_buffer_t)));
        if (arr == nullptr) {
            return LM_READ_COMM_ERROR;
        }
        for (std::size_t i = 0; i < certs.size(); ++i) {
            const auto& der = certs[i].derBytes;
            arr[i].length = der.size();
            arr[i].data = static_cast<std::uint8_t*>(std::malloc(der.size()));
            if (arr[i].data == nullptr) {
                lm_buffer_array_free(arr, i);
                return LM_READ_COMM_ERROR;
            }
            std::memcpy(arr[i].data, der.data(), der.size());
        }
        *out_certs = arr;
        *out_count = certs.size();
        return LM_READ_OK;
    } catch (const std::exception& e) {
        if (out_error_message != nullptr) {
            *out_error_message = duplicateAsCString(e.what());
        }
        return LM_READ_COMM_ERROR;
    } catch (...) {
        return LM_READ_COMM_ERROR;
    }
}

lm_pin_status_t lm_session_verify_pin(lm_session_t s,
                                      const char* pin_bytes,
                                      size_t pin_len,
                                      int32_t* out_retries_left,
                                      char** out_error_message)
{
    auto* h = reinterpret_cast<SessionHandle*>(s);
    if (h == nullptr || pin_bytes == nullptr) {
        return LM_PIN_DEVICE_ERROR;
    }
    try {
        // Build the Secure::String inside the bridge so the cleansing boundary
        // follows the PIN material from here all the way into the plugin's
        // verifyPIN override.
        LibreSCRS::Secure::String pin(std::string_view{pin_bytes, pin_len});
        auto r = h->plugin->verifyPIN(h->session, pin);
        if (out_retries_left != nullptr) {
            *out_retries_left = r.retriesLeft.value_or(-1);
        }
        using O = LibreSCRS::Plugin::PINResultOutcome;
        switch (r.outcome) {
            case O::Ok:          return LM_PIN_OK;
            case O::InvalidPin:  return LM_PIN_INCORRECT;
            case O::Blocked:     return LM_PIN_BLOCKED;
            case O::Unsupported: return LM_PIN_UNSUPPORTED;
            default:             return LM_PIN_DEVICE_ERROR;
        }
    } catch (const std::exception& e) {
        if (out_error_message != nullptr) {
            *out_error_message = duplicateAsCString(e.what());
        }
        return LM_PIN_DEVICE_ERROR;
    } catch (...) {
        return LM_PIN_DEVICE_ERROR;
    }
}

lm_sign_status_t lm_session_sign(lm_session_t s,
                                 uint16_t key_reference,
                                 lm_sign_mechanism_t mechanism,
                                 const uint8_t* data, size_t data_len,
                                 lm_buffer_t* out_signature,
                                 char** out_error_message)
{
    auto* h = reinterpret_cast<SessionHandle*>(s);
    if (h == nullptr || out_signature == nullptr || (data_len > 0 && data == nullptr)) {
        return LM_SIGN_DEVICE_ERROR;
    }
    try {
        std::span<const std::uint8_t> dataSpan{data, data_len};
        auto sig = h->plugin->sign(h->session, key_reference, dataSpan, mapSignMechanism(mechanism));
        using SO = LibreSCRS::Plugin::SignResultOutcome;
        switch (sig.outcome) {
            case SO::Ok: {
                out_signature->length = sig.signature.size();
                out_signature->data = static_cast<std::uint8_t*>(std::malloc(sig.signature.size()));
                if (out_signature->data == nullptr) {
                    return LM_SIGN_DEVICE_ERROR;
                }
                std::memcpy(out_signature->data, sig.signature.data(), sig.signature.size());
                return LM_SIGN_OK;
            }
            case SO::NotImplemented: return LM_SIGN_NOT_IMPLEMENTED;
            case SO::Cancelled:      return LM_SIGN_CANCELLED;
            default:                 return LM_SIGN_DEVICE_ERROR;
        }
    } catch (const std::exception& e) {
        if (out_error_message != nullptr) {
            *out_error_message = duplicateAsCString(e.what());
        }
        return LM_SIGN_DEVICE_ERROR;
    } catch (...) {
        return LM_SIGN_DEVICE_ERROR;
    }
}

} // extern "C"
