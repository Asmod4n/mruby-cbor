#pragma once

/*
 * mruby-cbor C API
 *
 * Include this header from C or C++ code that links against mruby-cbor.
 * For the higher-level C++ proxy API, include <mruby/cbor.hpp> instead.
 */

#include <mruby.h>

MRB_BEGIN_DECL

/*
 * Encoding
 */

/* Encode obj to a CBOR byte string (mrb_value of type String). */
MRB_API mrb_value mrb_cbor_encode(mrb_state *mrb, mrb_value obj);

/* Encode obj with shared-reference tags (Tag 28/29) for deduplication
 * and cyclic-structure support. */
MRB_API mrb_value mrb_cbor_encode_sharedrefs(mrb_state *mrb, mrb_value obj);

/* Fast encode — fixed-width integers/floats determined at compile time,
 * no UTF-8 scan, no tag support, no sharedrefs, no depth check.
 * Wire width: MRB_INT_BIT=16→uint16, MRB_INT_BIT=32→uint32, else→uint64.
 *             MRB_USE_FLOAT32→f32, else→f64.
 * Only decode with mrb_cbor_decode_fast. Do NOT mix with canonical buffers. */
MRB_API mrb_value mrb_cbor_encode_fast(mrb_state *mrb, mrb_value obj);

/*
 * Decoding
 */

/* Eagerly decode a CBOR byte string into a Ruby value.
 * buf must be a String mrb_value. */
MRB_API mrb_value mrb_cbor_decode(mrb_state *mrb, mrb_value buf);

/* Return a CBOR::Lazy object that wraps buf without decoding it. */
MRB_API mrb_value mrb_cbor_decode_lazy(mrb_state *mrb, mrb_value buf);

/* Materialize a CBOR::Lazy object into a fully decoded Ruby value.
 * lazy must be a CBOR::Lazy instance returned from mrb_cbor_decode_lazy. */
MRB_API mrb_value mrb_cbor_lazy_value(mrb_state *mrb, mrb_value lazy);

/* Fast decode — only valid on buffers produced by mrb_cbor_encode_fast.
 * No tag handling, no sharedrefs, no depth check. */
MRB_API mrb_value mrb_cbor_decode_fast(mrb_state *mrb, mrb_value buf);

/*
 * Streaming / framing
 */

/* Find the byte offset of the end of the first complete CBOR document in buf
 * starting at offset. Returns an Integer offset on success or nil if the
 * buffer does not yet contain a complete document. */
MRB_API mrb_value mrb_cbor_doc_end(mrb_state *mrb, mrb_value buf, mrb_int offset);

/*
 * Tag registration
 */

/* Register klass as the Ruby class for CBOR tag tag_num.
 * Equivalent to CBOR.register_tag(tag_num, klass) from Ruby. */
MRB_API void mrb_cbor_register_tag(mrb_state *mrb, uint64_t tag_num, struct RClass *klass);

MRB_END_DECL