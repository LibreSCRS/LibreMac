// SPDX-License-Identifier: LGPL-2.1-or-later
// SPDX-FileCopyrightText: 2026 hirashix0
//
// Stable extern "C" surface bridging Swift (LibreMac host app, future CTK
// appex) to LibreMiddleware C++ types. Per Stroustrup, A Tour of C++ 3e
// §15: a stable C ABI surface keeps the Swift / Obj-C++ side independent
// of the C++20 stdlib version that compiled LibreSCRS::*. Important
// because the Swift toolchain and the LM toolchain may not match
// exactly — the C ABI is the contract.

#ifndef LIBREMAC_BRIDGE_H
#define LIBREMAC_BRIDGE_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

// ---- Lifecycle --------------------------------------------------------

typedef struct lm_registry_s* lm_registry_t;
typedef struct lm_session_s*  lm_session_t;

/// Construct a CardPluginRegistry rooted at @p plugins_dir. The directory is
/// scanned for plugin shared objects (LibreMiddleware A5 manifest-driven
/// plugins ship as `lib<id>-plugin.dylib`). Returns nullptr on allocation
/// failure. The returned handle owns its dlopen handles for the lifetime of
/// the registry.
lm_registry_t lm_registry_create(const char* plugins_dir);

/// Destroy the registry. Plugin shared objects unmap when the last shared_ptr
/// referencing them drops (per LM 4.0 ABI v6 ownership semantics).
void lm_registry_destroy(lm_registry_t r);

/// Number of plugins successfully loaded by the registry. Returns -1 if @p r
/// is nullptr.
int lm_registry_plugin_count(lm_registry_t r);

// ---- Session ----------------------------------------------------------

typedef enum {
    LM_OPEN_OK = 0,
    LM_OPEN_READER_UNAVAILABLE = 1,
    LM_OPEN_NO_CARD = 2,
    LM_OPEN_PROTOCOL_ERROR = 3,
    /// Reader and card are functioning, but no LibreMiddleware plugin
    /// recognised the card (neither the ATR-based fast probe nor the
    /// AID-based live probe yielded a match). The host UI should render
    /// "this card is not supported" rather than a generic communication
    /// error. @since 4.0.
    LM_OPEN_NO_MATCHING_PLUGIN = 4,
} lm_open_status_t;

/// Open a session against @p reader_name. On failure populates @p out_status
/// with the OpenError::Kind translation, @p out_error_message with a
/// caller-owned UTF-8 string (free with lm_string_free), and returns null.
lm_session_t lm_session_open(lm_registry_t r,
                             const char* reader_name,
                             lm_open_status_t* out_status,
                             char** out_error_message);

/// Close the session. Pre-conditions: @p s must be the value returned by a
/// prior lm_session_open call and not yet passed to this function.
void lm_session_close(lm_session_t s);

// ---- Card data --------------------------------------------------------

typedef struct {
    uint8_t* data;     // caller-owned; free with lm_buffer_free
    size_t   length;
} lm_buffer_t;

typedef enum {
    LM_READ_OK = 0,
    LM_READ_COMM_ERROR = 1,
    LM_READ_PARSE_ERROR = 2,
    LM_READ_UNSUPPORTED = 3,
    LM_READ_AUTH_FAILED = 4,
} lm_read_status_t;

/// Enumerate certificates as DER buffers. On success populates @p out_certs
/// with a caller-owned array of lm_buffer_t (free each .data via
/// lm_buffer_free, then free the array via lm_buffer_array_free) and
/// @p out_count with its length.
lm_read_status_t lm_session_read_certificates(lm_session_t s,
                                              lm_buffer_t** out_certs,
                                              size_t* out_count,
                                              char** out_error_message);

// ---- PIN + Sign -------------------------------------------------------

typedef enum {
    LM_PIN_OK = 0,
    LM_PIN_INCORRECT = 1,
    LM_PIN_BLOCKED = 2,
    LM_PIN_UNSUPPORTED = 3,
    LM_PIN_DEVICE_ERROR = 4,
} lm_pin_status_t;

/// Verify @p pin_bytes (length @p pin_len) against the active session's
/// default PIN reference. The bridge wraps the bytes in a
/// `LibreSCRS::Secure::String` for the duration of the call so the cleansing
/// boundary spans the entire C++ path; the caller is still responsible for
/// not retaining @p pin_bytes after this returns.
lm_pin_status_t lm_session_verify_pin(lm_session_t s,
                                      const char* pin_bytes,
                                      size_t pin_len,
                                      int32_t* out_retries_left,
                                      char** out_error_message);

typedef enum {
    LM_SIGN_OK = 0,
    LM_SIGN_PIN_REQUIRED = 1,
    LM_SIGN_DEVICE_ERROR = 2,
    LM_SIGN_NOT_IMPLEMENTED = 3,
    LM_SIGN_CANCELLED = 4,
} lm_sign_status_t;

typedef enum {
    LM_MECH_RSA_PKCS = 1,
    LM_MECH_ECDSA_SHA256 = 2,
    LM_MECH_ECDSA_SHA384 = 3,
    LM_MECH_ECDSA_SHA512 = 4,
} lm_sign_mechanism_t;

/// Sign @p data with the on-card key at @p key_reference using @p mechanism.
///
/// @par Memory hygiene
/// The bridge takes a non-owning view over @p data for the duration of the
/// call; it does NOT copy, mutate, or zero the caller's buffer. When @p data
/// carries sensitive material (e.g. a hash of a sensitive document or PIN-
/// derived key material), the caller is responsible for cleansing the buffer
/// post-call. Mirrors the LibreMiddleware @c CardPlugin::sign contract — see
/// the @c data parameter doxygen there. @since 4.0.
lm_sign_status_t lm_session_sign(lm_session_t s,
                                 uint16_t key_reference,
                                 lm_sign_mechanism_t mechanism,
                                 const uint8_t* data, size_t data_len,
                                 lm_buffer_t* out_signature,
                                 char** out_error_message);

// ---- Memory hygiene ---------------------------------------------------

void lm_string_free(char* s);
void lm_buffer_free(uint8_t* p);
void lm_buffer_array_free(lm_buffer_t* arr, size_t count);

#ifdef __cplusplus
} // extern "C"
#endif

#endif /* LIBREMAC_BRIDGE_H */
