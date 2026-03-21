#pragma once

/*
 * mruby-cbor C++ API
 *
 * Provides a zero-overhead C++ wrapper over the mruby-cbor C API.
 * The Lazy proxy type mirrors simdjson's OnDemand design: operator[] chains
 * without raising immediately on a miss; the error is carried in the proxy
 * and only raised when .value() is called.
 *
 * Usage:
 *
 *   #include <mruby/cbor.hpp>
 *
 *   // Encode
 *   mrb_value buf = CBOR::encode(mrb, obj);
 *   mrb_value buf = CBOR::encode(mrb, obj, true);  // sharedrefs
 *
 *   // Eager decode
 *   mrb_value obj = CBOR::decode(mrb, buf);
 *
 *   // Lazy decode — operator[] chains, .value() materializes
 *   auto doc = CBOR::decode_lazy(mrb, buf);
 *   mrb_value text = doc["statuses"][0]["text"].value();
 *
 *   // Operator bool checks for error/nil before materializing
 *   auto field = doc["maybe"]["missing"];
 *   if (field) {
 *     mrb_value v = field.value();
 *   }
 *
 *   // doc_end for streaming
 *   mrb_value end_offset = CBOR::doc_end(mrb, buf, 0);
 *
 *   // Register a tag
 *   CBOR::register_tag(mrb, 1000, my_class);
 */

#include "mruby/num_helpers.hpp"
#include <mruby.h>
#include <mruby/class.h>
#include <mruby/error.h>
#include <mruby/presym.h>
#include <mruby/string.h>
#include <mruby/cbor.h>
#include <string_view>
#include <mruby/cpp_to_mrb_value.hpp>

namespace CBOR {

// ============================================================================
// Lazy — simdjson-style result-carrying proxy
//
// Each operator[] returns a new Lazy. If the underlying mrb call raises,
// the exception is cleared and the error is stored in the proxy. The error
// is re-raised lazily when .value() is called.
//
// operator bool returns false if the proxy carries an error or wraps nil.
// ============================================================================

class Lazy {
public:
  mrb_state *mrb;

  // Construct from a live handle (normal path)
  Lazy(mrb_state *mrb, mrb_value handle)
    : mrb(mrb), handle_(handle), has_error_(false), exc_(mrb_undef_value()) {}

  // Construct carrying a pending error (miss/error propagation path)
  Lazy(mrb_state *mrb, mrb_value exc, bool /*error_tag*/)
    : mrb(mrb), handle_(mrb_undef_value()), has_error_(true), exc_(exc) {}

  template <size_t N>
  Lazy operator[](const char (&key)[N]) const {
    return aref(mrb_str_new_static(mrb, key, N - 1));
  }

  Lazy operator[](std::string_view key) const {
    return aref(cpp_to_mrb_value(mrb, key));
  }

  Lazy operator[](mrb_value key) const {
    return aref(key);
  }

  // Integer index
  Lazy operator[](size_t idx) const {
    return aref(mrb_convert_number(mrb, idx));
  }

  // -------------------------------------------------------------------------
  // value() — materialize the decoded Ruby value.
  // Re-raises any carried error. Raises if called on a nil handle.
  // -------------------------------------------------------------------------
  mrb_value value() const {
    if (has_error_) {
      mrb_exc_raise(mrb, exc_);
      return mrb_undef_value(); // unreachable
    }

    mrb_value result = mrb_cbor_lazy_value(mrb, handle_);
    if (mrb->exc) {
      mrb_value exc = mrb_obj_value(mrb->exc);
      mrb->exc = nullptr;
      mrb_exc_raise(mrb, exc);
    }
    return result;
  }

  // -------------------------------------------------------------------------
  // operator bool — false if carrying an error or wrapping nil.
  // -------------------------------------------------------------------------
  explicit operator bool() const {
    return !has_error_ && !mrb_undef_p(handle_);
  }

  bool has_error() const { return has_error_; }

  // The underlying CBOR::Lazy mrb_value; mrb_undef_value() on error.
  mrb_value raw_handle() const {
    return has_error_ ? mrb_undef_value() : handle_;
  }

private:
  mrb_value handle_;
  bool      has_error_;
  mrb_value exc_;

  Lazy aref(mrb_value key) const {
    if (has_error_) return Lazy(mrb, exc_, true);

    if (mrb_nil_p(handle_)) {
      mrb_value exc = mrb_exc_new_str(mrb,
        mrb_class_get(mrb, "KeyError"),
        mrb_str_new_lit(mrb, "CBOR::Lazy: index into nil"));
      return Lazy(mrb, exc, true);
    }

    mrb_value result = mrb_funcall_argv(mrb, handle_, MRB_OPSYM(aref), 1, &key);

    if (mrb->exc) {
      mrb_value exc = mrb_obj_value(mrb->exc);
      mrb->exc = nullptr;
      return Lazy(mrb, exc, true);
    }

    return Lazy(mrb, result);
  }
};

// ============================================================================
// decode_lazy
// ============================================================================

inline Lazy decode_lazy(mrb_state *mrb, mrb_value buf) {
  mrb_value lazy = mrb_cbor_decode_lazy(mrb, buf);
  if (mrb->exc) {
    mrb_value exc = mrb_obj_value(mrb->exc);
    mrb->exc = nullptr;
    return Lazy(mrb, exc, true);
  }
  return Lazy(mrb, lazy);
}

// ============================================================================
// decode
// ============================================================================

inline mrb_value decode(mrb_state *mrb, mrb_value buf) {
  return mrb_cbor_decode(mrb, buf);
}

// ============================================================================
// encode
// ============================================================================

inline mrb_value encode(mrb_state *mrb, mrb_value obj, bool sharedrefs = false) {
  return sharedrefs
    ? mrb_cbor_encode_sharedrefs(mrb, obj)
    : mrb_cbor_encode(mrb, obj);
}

// ============================================================================
// doc_end
// ============================================================================

inline mrb_value doc_end(mrb_state *mrb, mrb_value buf, mrb_int offset = 0) {
  return mrb_cbor_doc_end(mrb, buf, offset);
}


// ============================================================================
// register_tag
// ============================================================================

inline void register_tag(mrb_state *mrb, mrb_int tag_num, struct RClass *klass) {
  mrb_cbor_register_tag(mrb, tag_num, klass);
}

} // namespace CBOR