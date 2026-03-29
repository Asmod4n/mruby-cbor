#include <mruby.h>
#include <mruby/string.h>
#include <mruby/array.h>
#include <mruby/hash.h>
#include <mruby/class.h>
MRB_BEGIN_DECL
#include <mruby/internal.h>
MRB_END_DECL
#include <mruby/num_helpers.h>
#include <mruby/branch_pred.h>
#include <mruby/presym.h>
#include <mruby/string_is_utf8.h>
#include <mruby/data.h>
#include <mruby/variable.h>
#include <mruby/error.h>
#include <mruby/ned.h>
#include <mruby/str_constantize.h>
#include <mruby/cbor.h>

#include <stdlib.h>
#include <stdint.h>
#include <stddef.h>
#include <string.h>
#include <stdbool.h>

/* Configurable CBOR recursion depth limits */
#ifndef CBOR_MAX_DEPTH
  #if defined(MRB_PROFILE_MAIN) || defined(MRB_PROFILE_HIGH)
    #define CBOR_MAX_DEPTH 128
  #elif defined(MRB_PROFILE_BASELINE)
    #define CBOR_MAX_DEPTH 64
  #else
    #define CBOR_MAX_DEPTH 32
  #endif
#endif

#define CBOR_TAG_CLASS UINT32_C(49999)

typedef struct {
  const uint8_t* base;
  const uint8_t* p;
  const uint8_t* end;

  uint8_t major;
  uint8_t info;

  mrb_int depth;
} Reader;

static uint8_t
reader_read8(mrb_state* mrb, Reader* r)
{
  if (likely(r->p < r->end)) return *r->p++;
  else mrb_raise(mrb, E_RUNTIME_ERROR, "unexpected end of buffer");
  return 0;
}

static void
reader_read_header(mrb_state *mrb, Reader *r)
{
  uint8_t b = reader_read8(mrb, r);
  r->major = (uint8_t)(b >> 5);
  r->info  = (uint8_t)(b & 0x1F);
}

static void
reader_init(Reader* r, const uint8_t* buf, size_t len)
{
  r->base   = buf;
  r->p      = buf;
  r->end    = buf + len;
  r->major  = 0;
  r->info   = 0;
  r->depth  = 0;
}

static void
reader_check_depth(mrb_state *mrb, Reader *r)
{
  if (likely(r->depth < CBOR_MAX_DEPTH))
    return;
  else
    mrb_raise(mrb, E_RUNTIME_ERROR, "CBOR nesting depth exceeded");
}

#define CBOR_SBO_STACK_CAP (16 * 1024)

typedef struct {
  mrb_state *mrb;

  uint8_t stack_buf[CBOR_SBO_STACK_CAP];
  size_t  stack_len;

  mrb_value heap_str;
  char    *heap_ptr;
  size_t   heap_len;
  size_t   heap_capa;
  mrb_int  arena_index;

  mrb_value seen;

  mrb_int depth;
} CborWriter;

/* Forward declarations */
static mrb_value cbor_tag_registry(mrb_state *mrb);
static mrb_value cbor_tag_rev_registry(mrb_state *mrb);
static mrb_value cbor_proc_tag_registry(mrb_state *mrb);
static mrb_value cbor_proc_tag_rev_registry(mrb_state *mrb);
static void      encode_registered_tag(CborWriter *w, mrb_value obj, mrb_int tag_num);
static mrb_value decode_registered_tag(mrb_state *mrb, Reader *r, mrb_value src, mrb_value sharedrefs, mrb_value klass);

static mrb_int
cbor_pdiff(mrb_state *mrb, const uint8_t *p, const uint8_t *base)
{
  mrb_int i = mrb_integer(mrb_to_int(mrb, mrb_convert_ptrdiff(mrb, p - base)));
  if (likely(i >= 0))
    return i;
  else
    mrb_raise(mrb, E_RANGE_ERROR, "ptrdiff was negative");
  return 0;
}

static uint8_t hex_nibble(uint8_t c)
{
  return (uint8_t)((c & 0xF) + ((c >> 6) & 1) * 9);
}

static void
hex_decode_scalar(uint8_t * restrict out, const char * restrict in, size_t n)
{
  for (size_t i = 0; i < n; i++) {
    out[i] = (uint8_t)(
      (hex_nibble((uint8_t)in[2*i    ]) << 4) |
       hex_nibble((uint8_t)in[2*i + 1])
    );
  }
}

// ============================================================================
// Reader: CBOR unsigned integer → mrb_value
// ============================================================================

static mrb_value
read_cbor_uint(mrb_state* mrb, Reader* r, uint8_t info)
{
  if (info < 24) return mrb_fixnum_value(info);

  const uint8_t* p   = r->p;
  const uint8_t* end = r->end;

  switch (info) {
    case 24:
      if (likely(p < end)) {
        r->p++;
        uint8_t u = p[0];
    #ifndef MRB_USE_BIGINT
        if (likely((uint64_t)u <= (uint64_t)MRB_INT_MAX + 1))
          return mrb_convert_uint8(mrb, u);
        else
          mrb_raise(mrb, E_RANGE_ERROR, "integer out of range");
    #else
        return mrb_convert_uint8(mrb, u);
    #endif
      } else {
        mrb_raise(mrb, E_RANGE_ERROR, "invalid uint8");
      }
      break;

    case 25:
      if (likely(end - p >= 2)) {
        r->p += 2;
        uint16_t u = ((uint16_t)p[0] << 8) | p[1];
    #ifndef MRB_USE_BIGINT
        if (likely((uint64_t)u <= (uint64_t)MRB_INT_MAX + 1))
          return mrb_convert_uint16(mrb, u);
        else
          mrb_raise(mrb, E_RANGE_ERROR, "integer out of range");
    #else
        return mrb_convert_uint16(mrb, u);
    #endif
      } else {
        mrb_raise(mrb, E_RANGE_ERROR, "invalid uint16");
      }
      break;

    case 26:
      if (likely(end - p >= 4)) {
        r->p += 4;
        uint32_t u =
          ((uint32_t)p[0] << 24) |
          ((uint32_t)p[1] << 16) |
          ((uint32_t)p[2] << 8)  |
          ((uint32_t)p[3]);
    #ifndef MRB_USE_BIGINT
        if (likely((uint64_t)u <= (uint64_t)MRB_INT_MAX + 1))
          return mrb_convert_uint32(mrb, u);
        else
          mrb_raise(mrb, E_RANGE_ERROR, "integer out of range");
    #else
        return mrb_convert_uint32(mrb, u);
    #endif
      } else {
        mrb_raise(mrb, E_RANGE_ERROR, "invalid uint32");
      }
      break;

    case 27:
      if (likely(end - p >= 8)) {
        r->p += 8;
        uint64_t u =
          ((uint64_t)p[0] << 56) | ((uint64_t)p[1] << 48) |
          ((uint64_t)p[2] << 40) | ((uint64_t)p[3] << 32) |
          ((uint64_t)p[4] << 24) | ((uint64_t)p[5] << 16) |
          ((uint64_t)p[6] << 8)  |  (uint64_t)p[7];
    #ifndef MRB_USE_BIGINT
        if (likely(u <= (uint64_t)MRB_INT_MAX + 1))
          return mrb_convert_uint64(mrb, u);
        else
          mrb_raise(mrb, E_RANGE_ERROR, "integer out of range");
    #else
        return mrb_convert_uint64(mrb, u);
    #endif
      } else {
        mrb_raise(mrb, E_RANGE_ERROR, "invalid uint64");
      }
      break;

    case 31:
      mrb_raise(mrb, E_NOTIMP_ERROR, "indefinite-length items not supported");
      break;
  }

  mrb_raisef(mrb, E_RUNTIME_ERROR, "invalid integer encoding: %d", info);
  return mrb_undef_value();
}

static mrb_int
cbor_value_to_len(mrb_state *mrb, mrb_value v)
{
  if (likely(mrb_integer_p(v))) {
    mrb_int n = mrb_integer(v);
    if (likely(n >= 0)) return n;
  }
  mrb_raise(mrb, E_RANGE_ERROR, "CBOR length out of range");
  return 0;
}

static void
reader_advance_checked(mrb_state *mrb, Reader *r, mrb_int len)
{
  if (likely(len >= 0 &&
             r->p <= r->end &&
             (mrb_int)(r->end - r->p) >= len)) {
    r->p += len;
    return;
  }
  mrb_raise(mrb, E_RANGE_ERROR, "CBOR data out of bounds");
}

static void
ensure_slice_bounds(mrb_state* mrb, mrb_value src, mrb_int off, mrb_int blen)
{
  mrb_int slen = RSTRING_LEN(src);
  if (likely(off >= 0 && blen >= 0 && off <= slen && blen <= slen - off))
    return;
  mrb_raise(mrb, E_RANGE_ERROR, "slice out of bounds");
}

// ============================================================================
// Integers
// ============================================================================
static mrb_value
decode_unsigned(mrb_state* mrb, Reader* r, uint8_t info)
{
  return read_cbor_uint(mrb, r, info);
}

static mrb_value
decode_negative(mrb_state* mrb, Reader* r, uint8_t info)
{
  int idx = mrb_gc_arena_save(mrb);
  mrb_value n = read_cbor_uint(mrb, r, info);

  if (likely(mrb_integer_p(n))) {
    mrb_int v = mrb_integer(n);
    return mrb_convert_mrb_int(mrb, -1 - v);
  }

#ifdef MRB_USE_BIGINT
  else if (mrb_bigint_p(n)) {
    mrb_value np1 = mrb_bint_add(mrb, n, mrb_fixnum_value(1));
    mrb_gc_protect(mrb, np1);
    mrb_value res = mrb_bint_neg(mrb, np1);
    mrb_gc_arena_restore(mrb, idx);
    mrb_gc_protect(mrb, res);
    return res;
  } else {
    mrb_raise(mrb, E_TYPE_ERROR, "payload is not a number");
  }
#else
  mrb_raise(mrb, E_RANGE_ERROR, "negative integer out of range");
  return mrb_undef_value();
#endif
}

// ============================================================================
// Bytes / Text
// ============================================================================
static mrb_value decode_value(mrb_state* mrb, Reader* r, mrb_value src, mrb_value sharedrefs);

static mrb_value
decode_text(mrb_state* mrb, Reader* r, mrb_value src, uint8_t info)
{
  mrb_value blen_v = read_cbor_uint(mrb, r, info);
  mrb_int blen = cbor_value_to_len(mrb, blen_v);
  mrb_int off = cbor_pdiff(mrb, r->p, r->base);

  if (likely(blen <= RSTRING_LEN(src) - off)) {
    mrb_value slice = mrb_str_byte_subseq(mrb, src, off, blen);

#ifdef MRB_UTF8_STRING
    if (likely(mrb_str_is_utf8(slice))) {
      r->p += blen;
      return slice;
    }
    mrb_raise(mrb, E_TYPE_ERROR, "string slice isn't utf8");
#else
    r->p += blen;
    return slice;
#endif
  }
  mrb_raise(mrb, E_RANGE_ERROR, "text string out of bounds");
  return mrb_undef_value();
}

static mrb_value
decode_bytes(mrb_state* mrb, Reader* r, mrb_value src, uint8_t info)
{
  mrb_value blen_v = read_cbor_uint(mrb, r, info);
  mrb_int blen = cbor_value_to_len(mrb, blen_v);
  mrb_int off = cbor_pdiff(mrb, r->p, r->base);

  if (likely(blen <= RSTRING_LEN(src) - off)) {
    r->p += blen;
    return mrb_str_byte_subseq(mrb, src, off, blen);
  }
  mrb_raise(mrb, E_RANGE_ERROR, "byte string out of bounds");
  return mrb_undef_value();
}

static mrb_value
decode_array(mrb_state* mrb, Reader* r, mrb_value src,
             uint8_t info, mrb_value sharedrefs, bool reg)
{
  mrb_value len_v = read_cbor_uint(mrb, r, info);
  mrb_int len = cbor_value_to_len(mrb, len_v);
  mrb_value ary = mrb_ary_new(mrb);
  int idx = mrb_gc_arena_save(mrb);

  if (reg) {
    mrb_ary_push(mrb, sharedrefs, ary);
  }

  for (mrb_int i = 0; i < len; i++) {
    mrb_ary_push(mrb, ary, decode_value(mrb, r, src, sharedrefs));
    mrb_gc_arena_restore(mrb, idx);
  }

  return ary;
}

static mrb_value
decode_map(mrb_state* mrb, Reader* r, mrb_value src,
           uint8_t info, mrb_value sharedrefs, bool reg)
{
  mrb_value len_v = read_cbor_uint(mrb, r, info);
  mrb_int len = cbor_value_to_len(mrb, len_v);
  mrb_value hash = mrb_hash_new(mrb);
  int idx = mrb_gc_arena_save(mrb);

  if (reg) {
    mrb_ary_push(mrb, sharedrefs, hash);
  }

  for (mrb_int i = 0; i < len; i++) {
    mrb_value key = decode_value(mrb, r, src, sharedrefs);
    mrb_value val = decode_value(mrb, r, src, sharedrefs);
    mrb_hash_set(mrb, hash, key, val);
    mrb_gc_arena_restore(mrb, idx);
  }

  return hash;
}

static mrb_value
decode_null_with_skip(mrb_state *mrb, Reader *r, uint8_t info)
{
  if (info == 24) {
    reader_read8(mrb, r);
  }
  return mrb_nil_value();
}

// ============================================================================
// Simple / Float
// ============================================================================
#ifndef MRB_NO_FLOAT
static mrb_value
decode_float(mrb_state *mrb, Reader *r, uint8_t info)
{
  switch (info) {
    case 25: { /* Float16 */
      uint16_t h =
        ((uint16_t)reader_read8(mrb, r) << 8) |
        ((uint16_t)reader_read8(mrb, r));

      uint16_t sign = h & 0x8000u;
      uint16_t exp  = h & 0x7C00u;
      uint16_t frac = h & 0x03FFu;
      uint32_t u;

      if (exp == 0x7C00u) {
        u = ((uint32_t)sign << 16) | 0x7F800000u | ((uint32_t)frac << 13);
      } else if (exp != 0) {
        uint32_t new_exp  = (uint32_t)((exp >> 10) + (127 - 15)) << 23;
        uint32_t new_frac = (uint32_t)frac << 13;
        u = ((uint32_t)sign << 16) | new_exp | new_frac;
      } else if (frac == 0) {
        u = (uint32_t)sign << 16;
      } else {
        uint32_t mant = frac;
        int shift = 0;
        while ((mant & 0x0400u) == 0) { mant <<= 1; shift++; }
        mant &= 0x03FFu;
        uint32_t new_exp  = (uint32_t)(127 - 14 - shift) << 23;
        uint32_t new_frac = mant << 13;
        u = ((uint32_t)sign << 16) | new_exp | new_frac;
      }

      float f32;
      memcpy(&f32, &u, sizeof(float));
      return mrb_convert_float(mrb, f32);
    }

    case 26: { /* Float32 */
      uint32_t u =
        ((uint32_t)reader_read8(mrb, r) << 24) |
        ((uint32_t)reader_read8(mrb, r) << 16) |
        ((uint32_t)reader_read8(mrb, r) << 8)  |
        ((uint32_t)reader_read8(mrb, r));
      float f32;
      memcpy(&f32, &u, sizeof(float));
      return mrb_convert_float(mrb, f32);
    }

    case 27: { /* Float64 */
      uint64_t u =
        ((uint64_t)reader_read8(mrb, r) << 56) |
        ((uint64_t)reader_read8(mrb, r) << 48) |
        ((uint64_t)reader_read8(mrb, r) << 40) |
        ((uint64_t)reader_read8(mrb, r) << 32) |
        ((uint64_t)reader_read8(mrb, r) << 24) |
        ((uint64_t)reader_read8(mrb, r) << 16) |
        ((uint64_t)reader_read8(mrb, r) << 8)  |
        ((uint64_t)reader_read8(mrb, r));
      double f64;
      memcpy(&f64, &u, sizeof(double));
      return mrb_convert_double(mrb, f64);
    }

    default:
      mrb_raise(mrb, E_RUNTIME_ERROR, "invalid float encoding");
  }

  return mrb_undef_value();
}
#endif

#ifdef MRB_USE_BIGINT
static mrb_value
decode_tagged_bignum(mrb_state* mrb, Reader* r, mrb_value src, mrb_value tag)
{
  mrb_int idx = mrb_gc_arena_save(mrb);

  uint8_t b2 = reader_read8(mrb, r);
  uint8_t major2 = (uint8_t)(b2 >> 5);
  uint8_t info2  = (uint8_t)(b2 & 0x1F);

  if (likely(major2 == 2)) {
    mrb_value len_v = read_cbor_uint(mrb, r, info2);
    mrb_int len = cbor_value_to_len(mrb, len_v);

    if (likely(len >= 0)) {
      if (len == 0) {
        mrb_gc_arena_restore(mrb, idx);
        const mrb_bool negative = (mrb_cmp(mrb, tag, mrb_fixnum_value(3)) == 0);
        return mrb_fixnum_value(negative ? -1 : 0);
      }
      ptrdiff_t off = r->p - r->base;
      if (likely(off >= 0)) {
        ensure_slice_bounds(mrb, src, (mrb_int)off, len);
        r->p += len;

        const uint8_t* buf = (const uint8_t*)RSTRING_PTR(src) + off;
        const mrb_bool negative = (mrb_cmp(mrb, tag, mrb_fixnum_value(3)) == 0);
        const uint8_t* bigbuf = buf;

#ifndef MRB_ENDIAN_BIG
        if (likely(len > 1)) {
          uint8_t *tmp = mrb_alloca(mrb, len);
          memcpy(tmp, buf, len);
          for (mrb_int i = 0, j = len - 1; i < j; i++, j--) {
            uint8_t t = tmp[i]; tmp[i] = tmp[j]; tmp[j] = t;
          }
          bigbuf = tmp;
        }
#endif

        mrb_value n = mrb_bint_from_bytes(mrb, bigbuf, len);
        mrb_gc_arena_restore(mrb, idx);
        mrb_gc_protect(mrb, n);

        if (!negative) return n;

        if (mrb_integer_p(n)) {
          mrb_int v = mrb_integer(n);
          return mrb_convert_mrb_int(mrb, -1 - v);
        } else if (mrb_bigint_p(n)) {
          mrb_value one = mrb_fixnum_value(1);
          mrb_value n_plus_1 = mrb_bint_add(mrb, n, one);
          mrb_gc_protect(mrb, n_plus_1);
          mrb_value ret = mrb_bint_neg(mrb, n_plus_1);
          mrb_gc_arena_restore(mrb, idx);
          mrb_gc_protect(mrb, ret);
          return ret;
        } else {
          mrb_bug(mrb, "mrb_bint_from_bytes didnt return a int or bigint");
        }
      } else {
        mrb_raise(mrb, E_RANGE_ERROR, "reader offset negative");
      }
    } else {
      mrb_raise(mrb, E_RANGE_ERROR, "bignum payload length out of range");
    }
  } else {
    mrb_raise(mrb, E_RUNTIME_ERROR, "invalid bignum payload");
  }

  return mrb_undef_value();
}
#endif

static mrb_value
decode_tag_sharedrefs(mrb_state* mrb, Reader* r,
                     mrb_value src, mrb_value sharedrefs)
{
  uint8_t nb = reader_read8(mrb, r);
  uint8_t major = nb >> 5;
  uint8_t info  = nb & 0x1F;

  switch (major) {
    case 4: return decode_array(mrb, r, src, info, sharedrefs, true);
    case 5: return decode_map(mrb, r, src, info, sharedrefs, true);
  }

  r->p--;
  mrb_value v = decode_value(mrb, r, src, sharedrefs);
  mrb_ary_push(mrb, sharedrefs, v);
  return v;
}

static mrb_value
decode_tag_sharedref(mrb_state* mrb, Reader* r, mrb_value sharedrefs)
{
  if (likely(mrb_array_p(sharedrefs))) {
    uint8_t ref_b     = reader_read8(mrb, r);
    uint8_t ref_major = ref_b >> 5;
    uint8_t ref_info  = ref_b & 0x1F;

    if (likely(ref_major == 0)) {
      mrb_value idx_v = read_cbor_uint(mrb, r, ref_info);
      mrb_int idx = cbor_value_to_len(mrb, idx_v);
      mrb_value found = mrb_ary_ref(mrb, sharedrefs, idx);

      if (likely(!mrb_nil_p(found))) {
        return found;
      } else {
        mrb_raise(mrb, E_INDEX_ERROR, "sharedref index not found");
      }
    } else {
      mrb_raise(mrb, E_TYPE_ERROR, "sharedref payload must be unsigned integer");
    }
  } else {
    mrb_raise(mrb, E_RUNTIME_ERROR, "CBOR internal error: sharedrefs is not a array");
  }

  return mrb_undef_value();
}

static mrb_value
cbor_sym_strategy(mrb_state *mrb)
{
  struct RClass *mod = mrb_module_get_id(mrb, MRB_SYM(CBOR));
  mrb_value v = mrb_iv_get(mrb, mrb_obj_value(mod), MRB_SYM(__sym_strat__));
  if (mrb_nil_p(v)) return mrb_fixnum_value(0);
  return v;
}

static void
cbor_set_sym_strategy(mrb_state *mrb, uint8_t mode)
{
  struct RClass *mod = mrb_module_get_id(mrb, MRB_SYM(CBOR));
  mrb_iv_set(mrb, mrb_obj_value(mod), MRB_SYM(__sym_strat__), mrb_fixnum_value(mode));
}

static mrb_value
decode_symbol(mrb_state *mrb, Reader* r, mrb_value src, mrb_value sharedrefs)
{
  mrb_value strategy = cbor_sym_strategy(mrb);

  if (unlikely(mrb_cmp(mrb, strategy, mrb_fixnum_value(0)) == 0)) {
    mrb_raise(mrb, E_RUNTIME_ERROR,
      "tag 39 encountered but symbol decoding disabled");
  }

  mrb_value v = decode_value(mrb, r, src, sharedrefs);

  if (mrb_cmp(mrb, strategy, mrb_fixnum_value(1)) == 0) {
    if (likely(mrb_string_p(v))) {
      return mrb_symbol_value(mrb_intern_str(mrb, v));
    } else {
      mrb_raise(mrb, E_TYPE_ERROR,
        "invalid payload for tag 39 (expected text string)");
    }
  }

  if (mrb_cmp(mrb, strategy, mrb_fixnum_value(2)) == 0) {
    if (likely(mrb_integer_p(v))) {
      mrb_int n = mrb_integer(v);
      if (likely(n >= 0 && n <= UINT32_MAX)) {
        return mrb_symbol_value((mrb_sym)n);
      } else {
        mrb_raise(mrb, E_RANGE_ERROR, "invalid symbol ID size for tag 39");
      }
    } else {
      mrb_raise(mrb, E_TYPE_ERROR,
        "invalid payload for tag 39 (expected uint32)");
    }
  }

  mrb_raise(mrb, E_RUNTIME_ERROR, "invalid symbol strategy");
  return mrb_nil_value();
}

static mrb_value
decode_class(mrb_state *mrb, Reader *r, mrb_value src, mrb_value sharedrefs)
{
  mrb_value v = decode_value(mrb, r, src, sharedrefs);
  if (likely(mrb_string_p(v)))
    return mrb_str_constantize(mrb, v);
  mrb_raise(mrb, E_TYPE_ERROR, "invalid payload for tag 49999 (expected text string)");
  return mrb_undef_value();
}

static mrb_value
decode_class_tag(mrb_state *mrb, Reader *r, mrb_value src, mrb_value sharedrefs, mrb_value tag)
{
  mrb_value reg   = cbor_tag_registry(mrb);
  mrb_value klass = mrb_hash_fetch(mrb, reg, tag, mrb_undef_value());
  if (mrb_class_p(klass))
    return decode_registered_tag(mrb, r, src, sharedrefs, klass);
  return mrb_undef_value();
}

static mrb_value
decode_proc_tag(mrb_state *mrb, Reader *r, mrb_value src, mrb_value sharedrefs, mrb_value tag)
{
  mrb_value proc_reg = cbor_proc_tag_registry(mrb);
  mrb_value entry    = mrb_hash_fetch(mrb, proc_reg, tag, mrb_undef_value());
  if (mrb_hash_p(entry)) {
    mrb_value decode_prc  = mrb_hash_fetch(mrb, entry, mrb_symbol_value(MRB_SYM(decode_proc)), mrb_undef_value());
    if (mrb_proc_p(decode_prc)) {
      mrb_value decode_type = mrb_hash_fetch(mrb, entry, mrb_symbol_value(MRB_SYM(decode_type)), mrb_undef_value());
      mrb_value payload = decode_value(mrb, r, src, sharedrefs);

      if (likely(mrb_net_check_type(mrb, decode_type, payload)))
        return mrb_yield_argv(mrb, decode_prc, 1, &payload);
      else
        mrb_raisef(mrb, E_TYPE_ERROR,
          "CBOR proc tag decode type mismatch for tag %v: got %C",
          tag, mrb_class(mrb, payload));
    }
  }
  return mrb_undef_value();
}

static mrb_value
decode_unhandled_tag(mrb_state *mrb, Reader *r, mrb_value src, mrb_value sharedrefs, mrb_value tag)
{
  mrb_value tagged_value = decode_value(mrb, r, src, sharedrefs);
  struct RClass *unhandled_tag = mrb_class_get_under_id(mrb,
    mrb_module_get_id(mrb, MRB_SYM(CBOR)), MRB_SYM(UnhandledTag));
  mrb_value result = mrb_obj_new(mrb, unhandled_tag, 0, NULL);
  mrb_iv_set(mrb, result, MRB_IVSYM(tag),   tag);
  mrb_iv_set(mrb, result, MRB_IVSYM(value), tagged_value);
  return result;
}

// ============================================================================
// Master decode with depth protection
// ============================================================================
static mrb_value
decode_value(mrb_state* mrb, Reader* r, mrb_value src, mrb_value sharedrefs)
{
  reader_check_depth(mrb, r);
  r->depth++;

  mrb_value result = mrb_undef_value();

  uint8_t b = reader_read8(mrb, r);
  uint8_t major = (uint8_t)(b >> 5);
  uint8_t info = (uint8_t)(b & 0x1F);

  switch (major) {
    case 0: result = decode_unsigned(mrb, r, info); break;
    case 1: result = decode_negative(mrb, r, info); break;
    case 2: result = decode_bytes(mrb, r, src, info); break;
    case 3: result = decode_text(mrb, r, src, info); break;
    case 4: result = decode_array(mrb, r, src, info, sharedrefs, false); break;
    case 5: result = decode_map(mrb, r, src, info, sharedrefs, false); break;

    case 6: {
      mrb_value tag = read_cbor_uint(mrb, r, info);

#ifdef MRB_USE_BIGINT
      if (mrb_cmp(mrb, tag, mrb_fixnum_value(2)) == 0 ||
          mrb_cmp(mrb, tag, mrb_fixnum_value(3)) == 0) {
        result = decode_tagged_bignum(mrb, r, src, tag);
        goto done;
      }
#endif

      if (mrb_cmp(mrb, tag, mrb_fixnum_value(28)) == 0) {
        result = decode_tag_sharedrefs(mrb, r, src, sharedrefs);
        goto done;
      }
      if (mrb_cmp(mrb, tag, mrb_fixnum_value(29)) == 0) {
        result = decode_tag_sharedref(mrb, r, sharedrefs);
        goto done;
      }
      if (mrb_cmp(mrb, tag, mrb_fixnum_value(39)) == 0) {
        result = decode_symbol(mrb, r, src, sharedrefs);
        goto done;
      }
      if (mrb_cmp(mrb, tag, mrb_convert_uint32(mrb, CBOR_TAG_CLASS)) == 0) {
        result = decode_class(mrb, r, src, sharedrefs);
        goto done;
      }

      result = decode_class_tag(mrb, r, src, sharedrefs, tag);
      if (!mrb_undef_p(result)) goto done;

      result = decode_proc_tag(mrb, r, src, sharedrefs, tag);
      if (!mrb_undef_p(result)) goto done;

      result = decode_unhandled_tag(mrb, r, src, sharedrefs, tag);
    } break;

    case 7:
      if (info < 20) { result = mrb_nil_value(); break; }
      switch (info) {
        case 20: result = mrb_false_value(); break;
        case 21: result = mrb_true_value(); break;
        case 22:
        case 23: result = mrb_nil_value(); break;
        case 24: result = decode_null_with_skip(mrb, r, info); break;
#ifndef MRB_NO_FLOAT
        case 25:
        case 26:
        case 27: result = decode_float(mrb, r, info); break;
#endif
        case 31:
          mrb_raise(mrb, E_NOTIMP_ERROR, "indefinite-length items not supported");
          break;
      }
      if (unlikely(mrb_undef_p(result)))
        mrb_raise(mrb, E_RUNTIME_ERROR, "invalid simple/float");
      break;

    default:
      mrb_raisef(mrb, E_NOTIMP_ERROR, "Not implemented major type %d", major);
  }

done:
  r->depth--;
  return result;
}

static void
cbor_writer_init(CborWriter *w, mrb_state *mrb)
{
  w->mrb       = mrb;
  w->stack_len = 0;
  w->heap_str  = mrb_undef_value();
  w->heap_ptr  = NULL;
  w->heap_len  = 0;
  w->heap_capa = 0;
  w->arena_index = mrb_gc_arena_save(mrb);
  w->seen       = mrb_undef_value();
  w->depth      = 0;
}

static size_t next_pow2(size_t x)
{
  x--;
  x |= x >> 1; x |= x >> 2; x |= x >> 4; x |= x >> 8; x |= x >> 16;
#if SIZE_MAX > UINT32_MAX
  x |= x >> 32;
#endif
  x++;
  return x;
}

static void
cbor_writer_init_heap(CborWriter *w, size_t need)
{
  mrb_state *mrb = w->mrb;
  size_t stack_len = w->stack_len;

  if (likely(need <= SIZE_MAX - stack_len)) {
    size_t capa = next_pow2(stack_len + need);
    w->heap_str = mrb_str_new_capa(mrb, (mrb_int)capa);
    mrb_gc_register(mrb, w->heap_str);
    w->arena_index = mrb_gc_arena_save(mrb);
    struct RString *s = RSTRING(w->heap_str);
    w->heap_ptr  = RSTR_PTR(s);
    w->heap_capa = (size_t)RSTR_CAPA(s);
    if (likely(stack_len > 0)) {
      memcpy(w->heap_ptr, w->stack_buf, stack_len);
      w->heap_len = stack_len;
    } else {
      w->heap_len = 0;
    }
    return;
  }
  mrb_raise(mrb, E_RANGE_ERROR, "heap size overflow");
}

static void
cbor_writer_ensure_heap(CborWriter *w, size_t add)
{
  if (add <= w->heap_capa - w->heap_len) return;

  if (add <= SIZE_MAX - w->heap_len) {
    size_t capa = next_pow2(w->heap_len + add);
    mrb_str_resize(w->mrb, w->heap_str, (mrb_int)capa);
    struct RString *s = RSTRING(w->heap_str);
    w->heap_ptr  = RSTR_PTR(s);
    w->heap_capa = (size_t)RSTR_CAPA(s);
  } else {
    mrb_state *mrb = w->mrb;
    mrb_raise(mrb, E_RANGE_ERROR, "heap size overflow");
  }
}

static void
cbor_writer_write(CborWriter *w, const uint8_t *buf, size_t len)
{
  if (likely(len > 0)) {
    size_t stack_len = w->stack_len;
    if (mrb_undef_p(w->heap_str) && len <= CBOR_SBO_STACK_CAP - stack_len) {
      memcpy(w->stack_buf + stack_len, buf, len);
      w->stack_len = stack_len + len;
    } else {
      if (mrb_undef_p(w->heap_str)) {
        if (likely(len <= SIZE_MAX - stack_len)) {
          cbor_writer_init_heap(w, len);
        } else {
          mrb_state *mrb = w->mrb;
          mrb_raise(mrb, E_RANGE_ERROR, "heap size overflow");
        }
      }
      cbor_writer_ensure_heap(w, len);
      memcpy(w->heap_ptr + w->heap_len, buf, len);
      w->heap_len += len;
      mrb_gc_arena_restore(w->mrb, w->arena_index);
    }
  }
}

static mrb_value
cbor_writer_finish(CborWriter *w)
{
  mrb_state *mrb = w->mrb;
  if (mrb_hash_p(w->seen)) mrb_gc_unregister(mrb, w->seen);
  if (likely(mrb_undef_p(w->heap_str))) {
    return mrb_str_new(mrb, (const char*)w->stack_buf, (mrb_int)w->stack_len);
  } else if (mrb_string_p(w->heap_str)) {
    struct RString *s = RSTRING(w->heap_str);
    RSTR_SET_LEN(s, (mrb_int)w->heap_len);
    w->heap_ptr[w->heap_len] = '\0';
    mrb_gc_unregister(mrb, w->heap_str);
    return w->heap_str;
  } else {
    mrb_raise(mrb, E_RUNTIME_ERROR, "CBOR internal error: heap string is not a string");
  }
  return mrb_undef_value();
}

static void
encode_len(CborWriter *w, uint8_t major, uint64_t v)
{
  uint8_t buf[1 + 8];
  size_t  nbytes;

  if (v < 24) {
    buf[0] = (uint8_t)((major << 5) | (uint8_t)v); nbytes = 1;
  } else if (v <= 0xFFu) {
    buf[0] = (uint8_t)((major << 5) | 24); buf[1] = (uint8_t)v; nbytes = 2;
  } else if (v <= 0xFFFFu) {
    buf[0] = (uint8_t)((major << 5) | 25);
    buf[1] = (uint8_t)(v >> 8); buf[2] = (uint8_t)(v); nbytes = 3;
  } else if (v <= 0xFFFFFFFFu) {
    buf[0] = (uint8_t)((major << 5) | 26);
    buf[1] = (uint8_t)(v >> 24); buf[2] = (uint8_t)(v >> 16);
    buf[3] = (uint8_t)(v >> 8);  buf[4] = (uint8_t)(v); nbytes = 5;
  } else {
    buf[0] = (uint8_t)((major << 5) | 27);
    buf[1] = (uint8_t)(v >> 56); buf[2] = (uint8_t)(v >> 48);
    buf[3] = (uint8_t)(v >> 40); buf[4] = (uint8_t)(v >> 32);
    buf[5] = (uint8_t)(v >> 24); buf[6] = (uint8_t)(v >> 16);
    buf[7] = (uint8_t)(v >> 8);  buf[8] = (uint8_t)(v); nbytes = 9;
  }
  cbor_writer_write(w, buf, nbytes);
}

static void encode_integer(CborWriter *w, mrb_int n)
{
  if (n >= 0) encode_len(w, 0, (uint64_t)n);
  else        encode_len(w, 1, (uint64_t)(-1 - n));
}

static void encode_uint64(CborWriter *w, uint64_t v) { encode_len(w, 0, v); }

// ============================================================================
// Shared reference tracking
// ============================================================================

static mrb_bool
encode_check_shared(CborWriter *w, mrb_value obj)
{
  if (mrb_undef_p(w->seen)) return FALSE;
  mrb_state *mrb = w->mrb;

  mrb_value id_key = mrb_convert_mrb_int(mrb, mrb_obj_id(obj));
  mrb_value found  = mrb_hash_fetch(mrb, w->seen, id_key, mrb_undef_value());

  if (mrb_integer_p(found)) {
    uint8_t tag29[2] = { 0xD8, 0x1D };
    cbor_writer_write(w, tag29, 2);
    encode_len(w, 0, (uint64_t)mrb_integer(found));
    return TRUE;
  }

  mrb_hash_set(mrb, w->seen, id_key, mrb_convert_mrb_int(mrb, mrb_hash_size(mrb, w->seen)));
  uint8_t tag28[2] = { 0xD8, 0x1C };
  cbor_writer_write(w, tag28, 2);
  return FALSE;
}

// ============================================================================
// BigInt encoding (Tag 2/3)
// ============================================================================
#ifdef MRB_USE_BIGINT

struct encode_bignum_ctx {
  CborWriter *w;
  mrb_value   obj;
  char       *hbuf;
  uint8_t    *out;
};

static mrb_value
encode_bignum_body(mrb_state *mrb, void *ud)
{
  struct encode_bignum_ctx *ctx = (struct encode_bignum_ctx*) ud;
  CborWriter *w  = ctx->w;
  mrb_value   obj = ctx->obj;

  mrb_int idx  = mrb_gc_arena_save(mrb);
  mrb_int sign = mrb_bint_sign(mrb, obj);

  if (mrb_bint_size(mrb, obj) <= 8 && sign >= 0) {
    encode_uint64(w, mrb_bint_as_uint64(mrb, obj));
    mrb_gc_arena_restore(mrb, idx);
    return mrb_nil_value();
  }

  if (mrb_bint_size(mrb, obj) <= 8 && sign < 0) {
    mrb_value abs_obj = mrb_bint_abs(mrb, obj);
    mrb_gc_protect(mrb, abs_obj);
    uint64_t n = mrb_bint_as_uint64(mrb, abs_obj) - UINT64_C(1);
    encode_len(w, 1, n);
    mrb_gc_arena_restore(mrb, idx);
    return mrb_nil_value();
  }

  mrb_value mag = mrb_bint_abs(mrb, obj);
  mrb_gc_protect(mrb, mag);
  if (sign < 0) {
    mrb_value one = mrb_fixnum_value(1);
    mag = mrb_bint_sub(mrb, mag, one);
    mrb_gc_protect(mrb, mag);
  }

  mrb_value hex = mrb_bint_to_s(mrb, mag, 16);
  mrb_gc_protect(mrb, hex);

  mrb_int len  = RSTRING_LEN(hex);
  char   *hbuf = (char*)mrb_malloc(mrb, len + 2);
  ctx->hbuf    = hbuf;
  memcpy(hbuf, RSTRING_PTR(hex), len);
  hbuf[len] = '\0';

  mrb_gc_arena_restore(mrb, idx);

  char *p = hbuf;
  while (len > 0 && *p == '0') { p++; len--; }

  if (len == 0) {
    uint8_t tag = (sign < 0) ? 0xC3 : 0xC2;
    cbor_writer_write(w, &tag, 1);
    encode_len(w, 2, 1);
    uint8_t zero = 0;
    cbor_writer_write(w, &zero, 1);
    mrb_free(mrb, hbuf);
    ctx->hbuf = NULL;
    return mrb_nil_value();
  }

  mrb_bool odd      = (len & 1);
  mrb_int  byte_len = (odd ? len + 1 : len) / 2;

  if (sign < 0 && byte_len <= 8) {
    uint64_t n = 0;
    const char *q = p;
    for (mrb_int i = 0; i < len; i++)
      n = (n << 4) | hex_nibble((uint8_t)q[i]);
    encode_len(w, 1, n);
    mrb_free(mrb, hbuf);
    ctx->hbuf = NULL;
    return mrb_nil_value();
  }

  uint8_t tag = (sign < 0) ? 0xC3 : 0xC2;
  cbor_writer_write(w, &tag, 1);
  encode_len(w, 2, (uint64_t)byte_len);

  if (odd) { memmove(p + 1, p, len); p[0] = '0'; }

  uint8_t *out = (uint8_t*)mrb_malloc(mrb, byte_len);
  ctx->out     = out;
  hex_decode_scalar(out, p, byte_len);
  cbor_writer_write(w, out, (size_t)byte_len);

  mrb_free(mrb, hbuf); ctx->hbuf = NULL;
  mrb_free(mrb, out);  ctx->out  = NULL;

  return mrb_nil_value();
}

static void
encode_bignum(CborWriter *w, mrb_value obj)
{
  mrb_state *mrb = w->mrb;

  struct encode_bignum_ctx ctx = { w, obj, NULL, NULL };
  mrb_bool error = FALSE;
  mrb_value exc = mrb_protect_error(mrb, encode_bignum_body, &ctx, &error);

  if (ctx.hbuf) { mrb_free(mrb, ctx.hbuf); }
  if (ctx.out)  { mrb_free(mrb, ctx.out);  }

  if (error) { mrb_exc_raise(mrb, exc); }
}

#endif

// ============================================================================
// Array / Map
// ============================================================================
static void encode_value(CborWriter* w, mrb_value obj);

static void
encode_array(CborWriter* w, mrb_value ary)
{
  struct RBasic *basic_ary = mrb_basic_ptr(ary);
  unsigned int was_frozen = basic_ary->frozen;
  basic_ary->frozen = TRUE;
  mrb_int len = RARRAY_LEN(ary);
  encode_len(w, 4, (uint64_t)len);
  for (mrb_int i = 0; i < len; i++) encode_value(w, mrb_ary_ref(w->mrb, ary, i));
  basic_ary->frozen = was_frozen;
}

static int
encode_map_foreach(mrb_state *mrb, mrb_value key, mrb_value val, void *data)
{
  CborWriter *w = (CborWriter*)data;
  encode_value(w, key);
  encode_value(w, val);
  return 0;
}

static void
encode_map(CborWriter* w, mrb_value hash)
{
  mrb_state *mrb = w->mrb;
  struct RBasic *basic_hash = mrb_basic_ptr(hash);
  unsigned int was_frozen = basic_hash->frozen;
  basic_hash->frozen = TRUE;
  struct RHash *h = mrb_hash_ptr(hash);
  mrb_int len = mrb_hash_size(mrb, hash);
  encode_len(w, 5, (uint64_t)len);
  mrb_hash_foreach(mrb, h, encode_map_foreach, w);
  basic_hash->frozen = was_frozen;
}

static void
encode_string(CborWriter* w, mrb_value str)
{
  const char* p = RSTRING_PTR(str);
  mrb_int blen  = RSTRING_LEN(str);
  if (mrb_str_is_utf8(str)) encode_len(w, 3, (uint64_t)blen);
  else                      encode_len(w, 2, (uint64_t)blen);
  cbor_writer_write(w, (const uint8_t*)p, (size_t)blen);
}

static void
encode_class(CborWriter *w, mrb_value obj)
{
  mrb_state *mrb = w->mrb;
  mrb_value name = mrb_class_path(mrb, mrb_class_ptr(obj));

  if (likely(mrb_string_p(name))) {
    encode_len(w, 6, CBOR_TAG_CLASS);
    encode_string(w, name);
  } else {
    mrb_raise(mrb, E_ARGUMENT_ERROR, "cannot encode anonymous class/module");
  }
}

static void
encode_simple(CborWriter* w, mrb_value obj)
{
  uint8_t b;
  switch (mrb_type(obj)) {
    case MRB_TT_FALSE: b = mrb_nil_p(obj) ? 0xF6 : 0xF4; break;
    case MRB_TT_TRUE:  b = 0xF5; break;
    default: {
      mrb_state *mrb = w->mrb;
      mrb_raise(mrb, E_TYPE_ERROR, "unexpected simple value");
    }
  }
  cbor_writer_write(w, &b, 1);
}

#ifndef MRB_NO_FLOAT

static void
cbor_write_f16(CborWriter *w, uint32_t u32)
{
  uint32_t sign32  = u32 >> 31;
  uint32_t exp32   = (u32 >> 23) & 0xFF;
  uint32_t mant32  = u32 & 0x7FFFFF;
  uint32_t exp16, mant16;

  if (exp32 == 0xFF) {
    if (mant32 != 0) {
      uint8_t buf[3] = { 0xF9, 0x7E, 0x00 };
      cbor_writer_write(w, buf, 3);
      return;
    }
    exp16  = 0x1F;
    mant16 = 0;
  } else if (exp32 == 0) {
    exp16  = 0;
    mant16 = 0;
  } else if (exp32 >= 113) {
    exp16  = exp32 - 112;
    mant16 = mant32 >> 13;
  } else {
    mant16 = (0x800000u | mant32) >> (126 - exp32);
    exp16  = 0;
  }

  uint16_t h = (uint16_t)((sign32 << 15) | (exp16 << 10) | mant16);
  uint8_t buf[3] = { 0xF9, (uint8_t)(h >> 8), (uint8_t)h };
  cbor_writer_write(w, buf, 3);
}

#ifdef MRB_USE_FLOAT32

static void
encode_float(CborWriter *w, mrb_float f)
{
  mrb_static_assert(sizeof(mrb_float) == sizeof(uint32_t));
  uint32_t u32;
  memcpy(&u32, &f, 4);

  uint32_t exp32  = (u32 >> 23) & 0xFF;
  uint32_t mant32 = u32 & 0x7FFFFF;

  if (exp32 == 0xFF && mant32 != 0) { cbor_write_f16(w, u32); return; }

  mrb_bool fits_f16;
  if (exp32 == 0xFF || exp32 == 0) {
    fits_f16 = TRUE;
  } else if (exp32 >= 113 && exp32 <= 142) {
    fits_f16 = ((mant32 & 0x1FFFu) == 0);
  } else if (exp32 >= 103 && exp32 <= 112) {
    fits_f16 = ((mant32 & ((1u << (126 - exp32)) - 1u)) == 0);
  } else {
    fits_f16 = FALSE;
  }

  if (fits_f16) {
    cbor_write_f16(w, u32);
  } else {
    uint8_t buf[5] = {
      0xFA,
      (uint8_t)(u32 >> 24), (uint8_t)(u32 >> 16),
      (uint8_t)(u32 >>  8), (uint8_t)(u32)
    };
    cbor_writer_write(w, buf, 5);
  }
}

#else /* f64 build */

static void
encode_float(CborWriter *w, mrb_float f)
{
  mrb_static_assert(sizeof(mrb_float) == sizeof(uint64_t));
  uint64_t u64;
  memcpy(&u64, &f, 8);

  uint32_t exp64  = (uint32_t)((u64 >> 52) & 0x7FF);
  uint64_t mant64 = u64 & UINT64_C(0x000FFFFFFFFFFFFF);

  if (exp64 == 0x7FF && mant64 != 0) {
    cbor_write_f16(w, 0x7FC00000u);
    return;
  }

  if ((mant64 & UINT64_C(0x1FFFFFFF)) != 0) goto emit_f64;

  {
    uint32_t mant32 = (uint32_t)(mant64 >> 29);
    uint32_t sign32 = (uint32_t)(u64 >> 63);
    uint32_t exp32;

    if (exp64 == 0x7FF) {
      exp32 = 0xFF;
    } else if (exp64 == 0) {
      if (mant64 != 0) goto emit_f64;
      exp32 = 0;
    } else {
      if (exp64 < 897 || exp64 > 1150) goto emit_f64;
      exp32 = exp64 - 896;
    }

    uint32_t u32 = (sign32 << 31) | (exp32 << 23) | mant32;

    mrb_bool fits_f16;
    if (exp32 == 0xFF || exp32 == 0) {
      fits_f16 = TRUE;
    } else if (exp32 >= 113 && exp32 <= 142) {
      fits_f16 = ((mant32 & 0x1FFFu) == 0);
    } else if (exp32 >= 103 && exp32 <= 112) {
      fits_f16 = ((mant32 & ((1u << (126 - exp32)) - 1u)) == 0);
    } else {
      fits_f16 = FALSE;
    }

    if (fits_f16) {
      cbor_write_f16(w, u32);
      return;
    }

    uint8_t buf[5] = {
      0xFA,
      (uint8_t)(u32 >> 24), (uint8_t)(u32 >> 16),
      (uint8_t)(u32 >>  8), (uint8_t)(u32)
    };
    cbor_writer_write(w, buf, 5);
    return;
  }

emit_f64:;
  uint8_t buf[9] = {
    0xFB,
    (uint8_t)(u64 >> 56), (uint8_t)(u64 >> 48),
    (uint8_t)(u64 >> 40), (uint8_t)(u64 >> 32),
    (uint8_t)(u64 >> 24), (uint8_t)(u64 >> 16),
    (uint8_t)(u64 >>  8), (uint8_t)(u64)
  };
  cbor_writer_write(w, buf, 9);
}

#endif /* MRB_USE_FLOAT32 */
#endif /* MRB_NO_FLOAT */

static void
encode_sym(CborWriter *w, mrb_value obj)
{
  mrb_state *mrb = w->mrb;
  mrb_value mode = cbor_sym_strategy(mrb);

  if (mrb_cmp(mrb, mode, mrb_fixnum_value(0)) == 0) {
    encode_string(w, mrb_sym2str(mrb, mrb_symbol(obj)));
    return;
  }
  if (mrb_cmp(mrb, mode, mrb_fixnum_value(1)) == 0) {
    encode_len(w, 6, 39);
    encode_string(w, mrb_sym2str(mrb, mrb_symbol(obj)));
    return;
  }
  if (mrb_cmp(mrb, mode, mrb_fixnum_value(2)) == 0) {
    encode_len(w, 6, 39);
    encode_len(w, 0, mrb_symbol(obj));
    return;
  }
  mrb_raise(mrb, E_RUNTIME_ERROR, "invalid symbol strategy mode");
}

struct proc_tag_foreach_arg {
  CborWriter *w;
  mrb_value   obj;
  mrb_bool    found;
};

static int
proc_tag_foreach_cb(mrb_state *mrb, mrb_value enc_type, mrb_value entry, void *ud)
{
  struct proc_tag_foreach_arg *a = (struct proc_tag_foreach_arg *)ud;
  if (mrb_hash_p(entry) &&
      (mrb_class_p(enc_type) || mrb_module_p(enc_type)) &&
      mrb_obj_is_kind_of(mrb, a->obj, mrb_class_ptr(enc_type))) {
    mrb_value tag_v      = mrb_hash_fetch(mrb, entry, mrb_symbol_value(MRB_SYM(tag)),         mrb_undef_value());
    mrb_value encode_prc = mrb_hash_fetch(mrb, entry, mrb_symbol_value(MRB_SYM(encode_proc)), mrb_undef_value());
    if (mrb_integer_p(tag_v) && mrb_proc_p(encode_prc)) {
      mrb_value encoded = mrb_yield_argv(mrb, encode_prc, 1, &a->obj);
      encode_len(a->w, 6, (uint64_t)mrb_integer(tag_v));
      encode_value(a->w, encoded);
      a->found = TRUE;
      return 1;
    }
  }
  return 0;
}

static mrb_bool
encode_proc_tag(mrb_state *mrb, CborWriter *w, mrb_value obj)
{
  mrb_value proc_rev = cbor_proc_tag_rev_registry(mrb);
  struct proc_tag_foreach_arg a = {w, obj, FALSE };
  mrb_hash_foreach(mrb, mrb_hash_ptr(proc_rev), proc_tag_foreach_cb, &a);
  return a.found;
}

static void
encode_value(CborWriter* w, mrb_value obj)
{
  mrb_state* mrb = w->mrb;

  if (likely(w->depth < CBOR_MAX_DEPTH)) w->depth++;
  else mrb_raise(mrb, E_RUNTIME_ERROR, "CBOR nesting depth exceeded");

  if (!mrb_undef_p(w->seen) && !mrb_immediate_p(obj) && encode_check_shared(w, obj)) {
    w->depth--;
    return;
  }

  switch (mrb_type(obj)) {
    case MRB_TT_FALSE:
    case MRB_TT_TRUE:   encode_simple(w, obj); break;
    case MRB_TT_SYMBOL: encode_sym(w, obj); break;
#ifndef MRB_NO_FLOAT
    case MRB_TT_FLOAT:  encode_float(w, mrb_float(obj)); break;
#endif
    case MRB_TT_INTEGER: encode_integer(w, mrb_integer(obj)); break;
    case MRB_TT_CLASS:
    case MRB_TT_MODULE:  encode_class(w, obj); break;
    case MRB_TT_HASH:    encode_map(w, obj); break;
    case MRB_TT_ARRAY:   encode_array(w, obj); break;
    case MRB_TT_STRING:  encode_string(w, obj); break;
#ifdef MRB_USE_BIGINT
    case MRB_TT_BIGINT:  encode_bignum(w, obj); break;
#endif
    default: {
      mrb_value rev     = cbor_tag_rev_registry(mrb);
      mrb_value klass   = mrb_obj_value(mrb_class(mrb, obj));
      mrb_value tag_val = mrb_hash_fetch(mrb, rev, klass, mrb_undef_value());
      if (mrb_integer_p(tag_val)) {
        encode_registered_tag(w, obj, mrb_integer(tag_val));
      } else {
        if (!encode_proc_tag(mrb, w, obj)) {
          encode_string(w, mrb_obj_as_string(mrb, obj));
        }
      }
    } break;
  }

  w->depth--;
}

// ============================================================================
// Fast encode/decode — fixed-width, no branching on value ranges.
//
// Wire format determined entirely at compile time from mruby's build config:
//
//   MRB_INT_BIT == 16  → integers always uint16 (info=25, 3 bytes total)
//   MRB_INT_BIT == 32  → integers always uint32 (info=26, 5 bytes total)
//   default (64)       → integers always uint64 (info=27, 9 bytes total)
//
//   MRB_USE_FLOAT32    → floats always f32 (0xFA, 5 bytes total)
//   default            → floats always f64 (0xFB, 9 bytes total)
//
// Strings always encode as major 3 — no UTF-8 scan.
// Arrays/maps encode their count at the same fixed integer width.
// true/false/nil encode as standard 1-byte simples (unchanged).
//
// decode_fast only handles buffers produced by encode_fast.
// Do NOT mix fast and canonical buffers.
// ============================================================================

#if MRB_INT_BIT == 16
  #define CBOR_FAST_INT_INFO  25
  #define CBOR_FAST_INT_BYTES  2
  typedef uint16_t cbor_fast_uint_t;
  static void
  cbor_fast_write_uint(CborWriter *w, uint8_t major, uint16_t v)
  {
    uint8_t buf[3] = {
      (uint8_t)((major << 5) | 25),
      (uint8_t)(v >> 8), (uint8_t)(v)
    };
    cbor_writer_write(w, buf, 3);
  }
#elif MRB_INT_BIT == 32
  #define CBOR_FAST_INT_INFO  26
  #define CBOR_FAST_INT_BYTES  4
  typedef uint32_t cbor_fast_uint_t;
  static void
  cbor_fast_write_uint(CborWriter *w, uint8_t major, uint32_t v)
  {
    uint8_t buf[5] = {
      (uint8_t)((major << 5) | 26),
      (uint8_t)(v >> 24), (uint8_t)(v >> 16),
      (uint8_t)(v >>  8), (uint8_t)(v)
    };
    cbor_writer_write(w, buf, 5);
  }
#else
  #define CBOR_FAST_INT_INFO  27
  #define CBOR_FAST_INT_BYTES  8
  typedef uint64_t cbor_fast_uint_t;
  static void
  cbor_fast_write_uint(CborWriter *w, uint8_t major, uint64_t v)
  {
    uint8_t buf[9] = {
      (uint8_t)((major << 5) | 27),
      (uint8_t)(v >> 56), (uint8_t)(v >> 48),
      (uint8_t)(v >> 40), (uint8_t)(v >> 32),
      (uint8_t)(v >> 24), (uint8_t)(v >> 16),
      (uint8_t)(v >>  8), (uint8_t)(v)
    };
    cbor_writer_write(w, buf, 9);
  }
#endif

#ifdef MRB_USE_FLOAT32
  #define CBOR_FAST_FLOAT_INFO  26
  #define CBOR_FAST_FLOAT_BYTES  4
  static void
  cbor_fast_write_float(CborWriter *w, mrb_float f)
  {
    mrb_static_assert(sizeof(mrb_float) == sizeof(uint32_t));
    uint32_t u; memcpy(&u, &f, 4);
    uint8_t buf[5] = {
      0xFA,
      (uint8_t)(u >> 24), (uint8_t)(u >> 16),
      (uint8_t)(u >>  8), (uint8_t)(u)
    };
    cbor_writer_write(w, buf, 5);
  }
#else
  #define CBOR_FAST_FLOAT_INFO  27
  #define CBOR_FAST_FLOAT_BYTES  8
  static void
  cbor_fast_write_float(CborWriter *w, mrb_float f)
  {
    mrb_static_assert(sizeof(mrb_float) == sizeof(uint64_t));
    uint64_t u; memcpy(&u, &f, 8);
    uint8_t buf[9] = {
      0xFB,
      (uint8_t)(u >> 56), (uint8_t)(u >> 48),
      (uint8_t)(u >> 40), (uint8_t)(u >> 32),
      (uint8_t)(u >> 24), (uint8_t)(u >> 16),
      (uint8_t)(u >>  8), (uint8_t)(u)
    };
    cbor_writer_write(w, buf, 9);
  }
#endif

static void encode_value_fast(CborWriter *w, mrb_value obj);

static void
encode_array_fast(CborWriter *w, mrb_value ary)
{
  mrb_int len = RARRAY_LEN(ary);
  encode_len(w, 4, (uint64_t)len);          /* canonical shortest-form length */
  for (mrb_int i = 0; i < len; i++)
    encode_value_fast(w, mrb_ary_ref(w->mrb, ary, i));
}

static int
encode_map_fast_foreach(mrb_state *mrb, mrb_value key, mrb_value val, void *data)
{
  encode_value_fast((CborWriter*)data, key);
  encode_value_fast((CborWriter*)data, val);
  return 0;
}

static void
encode_map_fast(CborWriter *w, mrb_value hash)
{
  mrb_state *mrb = w->mrb;
  encode_len(w, 5, (uint64_t)mrb_hash_size(mrb, hash)); /* canonical shortest-form length */
  mrb_hash_foreach(mrb, mrb_hash_ptr(hash), encode_map_fast_foreach, w);
}

static void
encode_value_fast(CborWriter *w, mrb_value obj)
{
  mrb_state *mrb = w->mrb;
  if (likely(w->depth < CBOR_MAX_DEPTH)) w->depth++;
  else mrb_raise(mrb, E_RUNTIME_ERROR, "CBOR nesting depth exceeded");

  switch (mrb_type(obj)) {
    case MRB_TT_FALSE:
    case MRB_TT_TRUE:
      encode_simple(w, obj);
      break;
    case MRB_TT_INTEGER: {
      mrb_int n = mrb_integer(obj);
      if (n >= 0) cbor_fast_write_uint(w, 0, (cbor_fast_uint_t)n);
      else        cbor_fast_write_uint(w, 1, (cbor_fast_uint_t)(-1 - n));
      break;
    }
#ifndef MRB_NO_FLOAT
    case MRB_TT_FLOAT:
      cbor_fast_write_float(w, mrb_float(obj));
      break;
#endif
    case MRB_TT_STRING: {
      mrb_int blen = RSTRING_LEN(obj);
      encode_len(w, 3, (uint64_t)blen);     /* canonical shortest-form length */
      cbor_writer_write(w, (const uint8_t*)RSTRING_PTR(obj), (size_t)blen);
      break;
    }
    case MRB_TT_ARRAY: encode_array_fast(w, obj); break;
    case MRB_TT_HASH:  encode_map_fast(w, obj);   break;
    case MRB_TT_SYMBOL: {
      /* always tag 39 + string — no strategy config, same build both ends */
      encode_len(w, 6, 39);
      mrb_value s = mrb_sym2str(mrb, mrb_symbol(obj));
      mrb_int blen = RSTRING_LEN(s);
      encode_len(w, 3, (uint64_t)blen);
      cbor_writer_write(w, (const uint8_t*)RSTRING_PTR(s), (size_t)blen);
      break;
    }
    case MRB_TT_CLASS:
    case MRB_TT_MODULE: {
      mrb_value name = mrb_class_path(mrb, mrb_class_ptr(obj));
      if (likely(mrb_string_p(name))) {
        encode_len(w, 6, CBOR_TAG_CLASS);
        mrb_int blen = RSTRING_LEN(name);
        encode_len(w, 3, (uint64_t)blen);
        cbor_writer_write(w, (const uint8_t*)RSTRING_PTR(name), (size_t)blen);
      } else {
        mrb_raise(mrb, E_ARGUMENT_ERROR, "cannot encode anonymous class/module");
      }
      break;
    }
    default:
      /* Registered classes, bigints, UnhandledTag, proc-tag types —
       * fall back to canonical encoder so fast path is always correct */
      encode_value(w, obj);
      break;
  }
  w->depth--;
}

// ============================================================================
// Fast decoder
// ============================================================================

static mrb_value decode_value_fast(mrb_state *mrb, Reader *r, mrb_value src);

static mrb_value
decode_uint_fast(mrb_state *mrb, Reader *r)
{
  const uint8_t *p = r->p;
#if MRB_INT_BIT == 16
  if (likely(r->end - p >= 2)) {
    r->p += 2;
    return mrb_convert_uint16(mrb, ((uint16_t)p[0] << 8) | p[1]);
  } else {
    mrb_raise(mrb, E_RANGE_ERROR, "fast: truncated uint16");
  }
#elif MRB_INT_BIT == 32
  if (likely(r->end - p >= 4)) {
    r->p += 4;
    return mrb_convert_uint32(mrb,
      ((uint32_t)p[0] << 24) | ((uint32_t)p[1] << 16) |
      ((uint32_t)p[2] <<  8) |  (uint32_t)p[3]);
  } else {
    mrb_raise(mrb, E_RANGE_ERROR, "fast: truncated uint32");
  }
#else
  if (likely(r->end - p >= 8)) {
    r->p += 8;
    return mrb_convert_uint64(mrb,
      ((uint64_t)p[0] << 56) | ((uint64_t)p[1] << 48) |
      ((uint64_t)p[2] << 40) | ((uint64_t)p[3] << 32) |
      ((uint64_t)p[4] << 24) | ((uint64_t)p[5] << 16) |
      ((uint64_t)p[6] <<  8) |  (uint64_t)p[7]);
  } else {
    mrb_raise(mrb, E_RANGE_ERROR, "fast: truncated uint64");
  }
#endif
  return mrb_undef_value();
}

#ifndef MRB_NO_FLOAT
static mrb_value
decode_float_fast(mrb_state *mrb, Reader *r)
{
  const uint8_t *p = r->p;
#ifdef MRB_USE_FLOAT32
  if (likely(r->end - p >= 4)) {
    r->p += 4;
    uint32_t u =
      ((uint32_t)p[0] << 24) | ((uint32_t)p[1] << 16) |
      ((uint32_t)p[2] <<  8) |  (uint32_t)p[3];
    float f32; memcpy(&f32, &u, 4);
    return mrb_convert_float(mrb, f32);
  } else {
    mrb_raise(mrb, E_RANGE_ERROR, "fast: truncated float32");
  }
#else
  if (likely(r->end - p >= 8)) {
    r->p += 8;
    uint64_t u =
      ((uint64_t)p[0] << 56) | ((uint64_t)p[1] << 48) |
      ((uint64_t)p[2] << 40) | ((uint64_t)p[3] << 32) |
      ((uint64_t)p[4] << 24) | ((uint64_t)p[5] << 16) |
      ((uint64_t)p[6] <<  8) |  (uint64_t)p[7];
    double f64; memcpy(&f64, &u, 8);
    return mrb_convert_double(mrb, f64);
  } else {
    mrb_raise(mrb, E_RANGE_ERROR, "fast: truncated float64");
  }
#endif
  return mrb_undef_value();
}
#endif

static mrb_value
decode_value_fast(mrb_state *mrb, Reader *r, mrb_value src)
{
  reader_check_depth(mrb, r);
  r->depth++;

  mrb_value result = mrb_undef_value();
  if (likely(r->p < r->end)) {
    uint8_t b     = *r->p++;
    uint8_t major = b >> 5;
    uint8_t info  = b & 0x1F;

    switch (major) {
      case 0: {
        if (likely(info == CBOR_FAST_INT_INFO)) {
          result = decode_uint_fast(mrb, r);
        } else {
          mrb_raisef(mrb, E_RUNTIME_ERROR, "fast: unexpected int info %d", info);
        }
      } break;
      case 1: {
        if (likely(info == CBOR_FAST_INT_INFO)) {
          /* Read magnitude as unsigned, negate without intermediate mrb_value
           * to avoid signed overflow on e.g. -(MRB_INT_MIN) */
          const uint8_t *p = r->p;
#if MRB_INT_BIT == 16
          if (likely(r->end - p >= 2)) {
            r->p += 2;
            uint16_t u = ((uint16_t)p[0] << 8) | p[1];
            result = mrb_convert_mrb_int(mrb, -1 - (mrb_int)u);
          } else {
            mrb_raise(mrb, E_RANGE_ERROR, "fast: truncated uint16");
          }
#elif MRB_INT_BIT == 32
          if (likely(r->end - p >= 4)) {
            r->p += 4;
            uint32_t u =
              ((uint32_t)p[0] << 24) | ((uint32_t)p[1] << 16) |
              ((uint32_t)p[2] <<  8) |  (uint32_t)p[3];
            result = mrb_convert_mrb_int(mrb, -1 - (mrb_int)u);
          } else {
            mrb_raise(mrb, E_RANGE_ERROR, "fast: truncated uint32");
          }
#else
          if (likely(r->end - p >= 8)) {
            r->p += 8;
            uint64_t u =
              ((uint64_t)p[0] << 56) | ((uint64_t)p[1] << 48) |
              ((uint64_t)p[2] << 40) | ((uint64_t)p[3] << 32) |
              ((uint64_t)p[4] << 24) | ((uint64_t)p[5] << 16) |
              ((uint64_t)p[6] <<  8) |  (uint64_t)p[7];
            result = mrb_convert_mrb_int(mrb, -1 - (mrb_int)u);
          } else {
            mrb_raise(mrb, E_RANGE_ERROR, "fast: truncated uint64");
          }
#endif
        } else {
          mrb_raisef(mrb, E_RUNTIME_ERROR, "fast: unexpected neg info %d", info);
        }
      } break;
      case 3: {
        /* length canonical shortest-form */
        mrb_int blen = cbor_value_to_len(mrb, read_cbor_uint(mrb, r, info));
        mrb_int off  = cbor_pdiff(mrb, r->p, r->base);
        if (likely(blen >= 0 && blen <= RSTRING_LEN(src) - off)) {
          r->p += blen;
          result = mrb_str_byte_subseq(mrb, src, off, blen);
        } else {
          mrb_raise(mrb, E_RANGE_ERROR, "fast: string out of bounds");
        }
      } break;
      case 4: {
        /* length canonical shortest-form */
        mrb_int len = cbor_value_to_len(mrb, read_cbor_uint(mrb, r, info));
        mrb_value ary = mrb_ary_new(mrb);
        int idx = mrb_gc_arena_save(mrb);
        for (mrb_int i = 0; i < len; i++) {
          mrb_ary_push(mrb, ary, decode_value_fast(mrb, r, src));
          mrb_gc_arena_restore(mrb, idx);
        }
        result = ary;
      } break;
      case 5: {
        /* length canonical shortest-form */
        mrb_int len = cbor_value_to_len(mrb, read_cbor_uint(mrb, r, info));
        mrb_value hash = mrb_hash_new(mrb);
        int idx = mrb_gc_arena_save(mrb);
        for (mrb_int i = 0; i < len; i++) {
          mrb_value key = decode_value_fast(mrb, r, src);
          mrb_value val = decode_value_fast(mrb, r, src);
          mrb_hash_set(mrb, hash, key, val);
          mrb_gc_arena_restore(mrb, idx);
        }
        result = hash;
      } break;
      case 6: {
        /* tags: handle symbol (39) and class (49999), fall back to
         * canonical decode_value for everything else (registered tags,
         * bigints, sharedrefs, UnhandledTag) */
        mrb_value tag = read_cbor_uint(mrb, r, info);
        if (mrb_cmp(mrb, tag, mrb_fixnum_value(39)) == 0) {
          /* symbol — always encoded as tag 39 + string in fast path */
          mrb_value v = decode_value_fast(mrb, r, src);
          if (likely(mrb_string_p(v))) {
            result = mrb_symbol_value(mrb_intern_str(mrb, v));
          } else {
            mrb_raise(mrb, E_TYPE_ERROR, "fast: tag 39 payload must be string");
          }
        }
        else if (mrb_cmp(mrb, tag, mrb_convert_uint32(mrb, CBOR_TAG_CLASS)) == 0) {
          /* class/module — tag 49999 + string */
          mrb_value v = decode_value_fast(mrb, r, src);
          if (likely(mrb_string_p(v))) {
            result = mrb_str_constantize(mrb, v);
          } else {
            mrb_raise(mrb, E_TYPE_ERROR, "fast: tag 49999 payload must be string");
          }
        } else {
          mrb_value sharedrefs = mrb_ary_new(mrb);
          result = decode_class_tag(mrb, r, src, sharedrefs, tag);
          if (!mrb_undef_p(result))break;

          result = decode_proc_tag(mrb, r, src, sharedrefs, tag);
          if (!mrb_undef_p(result))break;

          result = decode_unhandled_tag(mrb, r, src, sharedrefs, tag);
        }
      } break;
      case 7:
        if (info < 20) { result = mrb_nil_value(); break; }
        switch (info) {
          case 20: result = mrb_false_value(); break;
          case 21: result = mrb_true_value(); break;
          case 22: result = mrb_nil_value(); break;
#ifndef MRB_NO_FLOAT
          case CBOR_FAST_FLOAT_INFO: result = decode_float_fast(mrb, r); break;
#endif
          default:
            mrb_raisef(mrb, E_RUNTIME_ERROR, "fast: unexpected simple info %d", info);
        } break;
      default:
        mrb_raisef(mrb, E_RUNTIME_ERROR, "fast: unsupported major type %d", major);
    }
  } else {
    mrb_raise(mrb, E_RUNTIME_ERROR, "fast: unexpected end of buffer");
  }
  r->depth--;
  return result;
}

static mrb_value
cbor_encode_fast_rb(mrb_state *mrb, mrb_value self)
{
  mrb_value obj;
  (void)self;
  mrb_get_args(mrb, "o", &obj);
  CborWriter w;
  cbor_writer_init(&w, mrb);
  encode_value_fast(&w, obj);
  return cbor_writer_finish(&w);
}

static mrb_value
cbor_decode_fast_rb(mrb_state *mrb, mrb_value self)
{
  mrb_value src;
  (void)self;
  mrb_get_args(mrb, "S", &src);
  mrb_value owned = mrb_str_byte_subseq(mrb, src, 0, RSTRING_LEN(src));
  Reader r;
  reader_init(&r, (const uint8_t*)RSTRING_PTR(owned), (size_t)RSTRING_LEN(owned));
  return decode_value_fast(mrb, &r, owned);
}

// ============================================================================
// CBOR::Lazy
// ============================================================================

typedef struct {
  mrb_value buf;
  mrb_int   offset;
} cbor_lazy_t;

static const struct mrb_data_type cbor_lazy_type = {
  "CBOR::Lazy", mrb_free
};

static mrb_value
cbor_lazy_new(mrb_state *mrb, mrb_value buf, mrb_int offset, mrb_value sharedrefs)
{
  struct RClass *cbor = mrb_module_get_id(mrb, MRB_SYM(CBOR));
  struct RClass *lazy = mrb_class_get_under_id(mrb, cbor, MRB_SYM(Lazy));

  cbor_lazy_t *p;
  struct RData *data;
  Data_Make_Struct(mrb, lazy, cbor_lazy_t, &cbor_lazy_type, p, data);

  p->buf    = buf;
  p->offset = offset;
  mrb_value obj = mrb_obj_value(data);
  mrb_iv_set(mrb, obj, MRB_SYM(buf),        buf);
  mrb_iv_set(mrb, obj, MRB_SYM(vcache),     mrb_undef_value());
  mrb_iv_set(mrb, obj, MRB_SYM(kcache),     mrb_hash_new(mrb));
  mrb_iv_set(mrb, obj, MRB_SYM(sharedrefs), sharedrefs);
  return obj;
}

// ============================================================================
// Tag registry
// ============================================================================

static mrb_value
cbor_tag_registry(mrb_state *mrb)
{
  mrb_value cbor = mrb_obj_value(mrb_module_get_id(mrb, MRB_SYM(CBOR)));
  mrb_value reg  = mrb_iv_get(mrb, cbor, MRB_SYM(__cbor_tag_registry__));
  if (likely(mrb_hash_p(reg))) return reg;
  reg = mrb_hash_new(mrb);
  mrb_iv_set(mrb, cbor, MRB_SYM(__cbor_tag_registry__), reg);
  return reg;
}

static mrb_value
cbor_tag_rev_registry(mrb_state *mrb)
{
  mrb_value cbor = mrb_obj_value(mrb_module_get_id(mrb, MRB_SYM(CBOR)));
  mrb_value reg  = mrb_iv_get(mrb, cbor, MRB_SYM(__cbor_tag_rev_registry__));
  if (likely(mrb_hash_p(reg))) return reg;
  reg = mrb_hash_new(mrb);
  mrb_iv_set(mrb, cbor, MRB_SYM(__cbor_tag_rev_registry__), reg);
  return reg;
}

static mrb_value
cbor_proc_tag_registry(mrb_state *mrb)
{
  mrb_value cbor = mrb_obj_value(mrb_module_get_id(mrb, MRB_SYM(CBOR)));
  mrb_value reg  = mrb_iv_get(mrb, cbor, MRB_SYM(__cbor_proc_tag_registry__));
  if (likely(mrb_hash_p(reg))) return reg;
  reg = mrb_hash_new(mrb);
  mrb_iv_set(mrb, cbor, MRB_SYM(__cbor_proc_tag_registry__), reg);
  return reg;
}

static mrb_value
cbor_proc_tag_rev_registry(mrb_state *mrb)
{
  mrb_value cbor = mrb_obj_value(mrb_module_get_id(mrb, MRB_SYM(CBOR)));
  mrb_value reg  = mrb_iv_get(mrb, cbor, MRB_SYM(__cbor_proc_tag_rev_registry__));
  if (likely(mrb_hash_p(reg))) return reg;
  reg = mrb_hash_new(mrb);
  mrb_iv_set(mrb, cbor, MRB_SYM(__cbor_proc_tag_rev_registry__), reg);
  return reg;
}

static void encode_value(CborWriter *w, mrb_value obj); /* forward */

// ============================================================================
// Registered tag encode/decode
// ============================================================================

typedef struct {
  CborWriter *w;
  mrb_value   obj;
} TagEncodeCtx;

static int
encode_registered_tag_foreach(mrb_state *mrb, mrb_value sym, mrb_value schema_type, void *data)
{
  TagEncodeCtx *ctx = (TagEncodeCtx*)data;
  CborWriter *w = ctx->w;
  mrb_value obj = ctx->obj;

  mrb_int slen;
  const char *sname = mrb_sym_name_len(mrb, mrb_symbol(sym), &slen);
  while (slen > 0 && sname[0] == '@') { sname++; slen--; }

  mrb_value val = mrb_iv_get(mrb, obj, mrb_symbol(sym));

  if (likely(mrb_net_check_type(mrb, schema_type, val))) {
    encode_len(w, 3, (uint64_t)slen);
    cbor_writer_write(w, (const uint8_t*)sname, (size_t)slen);
    encode_value(w, val);
  } else {
    mrb_raisef(mrb, E_TYPE_ERROR,
      "CBOR tag field type mismatch for ivar %v: expected %v, got %v",
      sym, schema_type, mrb_obj_value(mrb_class(mrb, val)));
  }

  return 0;
}

static void
encode_registered_tag(CborWriter *w, mrb_value obj, mrb_int tag_num)
{
  mrb_state *mrb = w->mrb;

  if (mrb_respond_to(mrb, obj, MRB_SYM(_before_encode))) {
    obj = mrb_funcall_argv(mrb, obj, MRB_SYM(_before_encode), 0, NULL);
  }

  mrb_value schema = mrb_net_schema(mrb, mrb_class(mrb, obj));
  if (likely(mrb_hash_p(schema))) {
    encode_len(w, 6, (uint64_t)tag_num);
    mrb_int n = mrb_hash_size(mrb, schema);
    encode_len(w, 5, (uint64_t)n);
    TagEncodeCtx ctx = { w, obj };
    struct RBasic *basic_ptr = mrb_basic_ptr(schema);
    unsigned int was_frozen = basic_ptr->frozen;
    basic_ptr->frozen = TRUE;
    mrb_hash_foreach(mrb, mrb_hash_ptr(schema), encode_registered_tag_foreach, &ctx);
    basic_ptr->frozen = was_frozen;
  } else {
    mrb_raise(mrb, E_RUNTIME_ERROR, "registered class has no net schema");
  }
}

typedef struct {
  mrb_value obj;
  mrb_value payload;
} decode_ctx;

static int
decode_registered_tag_foreach(mrb_state *mrb, mrb_value sym, mrb_value schema_type, void *data)
{
  decode_ctx *ctx = (decode_ctx*)data;

  mrb_int slen;
  const char *sname = mrb_sym_name_len(mrb, mrb_symbol(sym), &slen);
  while (slen > 0 && sname[0] == '@') { sname++; slen--; }

  mrb_value map_key = mrb_str_new_static(mrb, sname, slen);
  mrb_value val = mrb_hash_fetch(mrb, ctx->payload, map_key, mrb_undef_value());

  if (!mrb_undef_p(val)) {
    if (likely(mrb_net_check_type(mrb, schema_type, val))) {
      mrb_iv_set(mrb, ctx->obj, mrb_symbol(sym), val);
    } else {
      mrb_raisef(mrb, E_TYPE_ERROR,
        "CBOR tag field type mismatch for ivar %v: expected %v, got %v",
        sym, schema_type, mrb_obj_value(mrb_class(mrb, val)));
    }
  }

  return 0;
}

static mrb_value
decode_registered_tag(mrb_state *mrb, Reader *r, mrb_value src,
                      mrb_value sharedrefs, mrb_value klass)
{
  struct RClass *kp = mrb_class_ptr(klass);
  mrb_value schema  = mrb_net_schema(mrb, kp);
  mrb_value obj     = mrb_obj_value(mrb_obj_alloc(mrb, MRB_TT_OBJECT, kp));

  mrb_value payload = decode_value(mrb, r, src, sharedrefs);
  if (likely(mrb_hash_p(payload))) {
    if (likely(mrb_hash_p(schema))) {
      decode_ctx ctx = { obj, payload };
      struct RBasic *basic_ptr = mrb_basic_ptr(schema);
      unsigned int was_frozen = basic_ptr->frozen;
      basic_ptr->frozen = TRUE;
      mrb_hash_foreach(mrb, mrb_hash_ptr(schema), decode_registered_tag_foreach, &ctx);
      basic_ptr->frozen = was_frozen;

      if (mrb_respond_to(mrb, obj, MRB_SYM(_after_decode))) {
        return mrb_funcall_argv(mrb, obj, MRB_SYM(_after_decode), 0, NULL);
      } else {
        return obj;
      }
    } else {
      mrb_raise(mrb, E_RUNTIME_ERROR, "no schema found for registered class");
    }
  } else {
    mrb_raise(mrb, E_TYPE_ERROR, "registered tag payload must be a map");
  }

  return mrb_undef_value();
}

static void
skip_cbor(mrb_state *mrb, Reader *r, mrb_value buf, mrb_value sharedrefs)
{
  reader_check_depth(mrb, r);
  r->depth++;

  if (unlikely(r->p >= r->end))
    mrb_raise(mrb, E_RUNTIME_ERROR, "unexpected end of buffer");

  uint8_t b     = reader_read8(mrb, r);
  uint8_t major = b >> 5;
  uint8_t info  = b & 0x1F;

  switch (major) {
    case 0:
    case 1:
      if (info >= 24) read_cbor_uint(mrb, r, info);
      break;

    case 2:
    case 3: {
      mrb_value len_v = read_cbor_uint(mrb, r, info);
      reader_advance_checked(mrb, r, cbor_value_to_len(mrb, len_v));
      break;
    }

    case 4: {
      mrb_int len = cbor_value_to_len(mrb, read_cbor_uint(mrb, r, info));
      for (mrb_int i = 0; i < len; i++) skip_cbor(mrb, r, buf, sharedrefs);
      break;
    }

    case 5: {
      mrb_int len = cbor_value_to_len(mrb, read_cbor_uint(mrb, r, info));
      for (mrb_int i = 0; i < len; i++) {
        skip_cbor(mrb, r, buf, sharedrefs);
        skip_cbor(mrb, r, buf, sharedrefs);
      }
      break;
    }

    case 6: {
      mrb_value tag = read_cbor_uint(mrb, r, info);

      if (!mrb_undef_p(buf) && !mrb_undef_p(sharedrefs) &&
          mrb_cmp(mrb, tag, mrb_fixnum_value(28)) == 0) {
        if (likely(mrb_array_p(sharedrefs))) {
          mrb_int inner_offset = cbor_pdiff(mrb, r->p, r->base);
          mrb_value lazy = cbor_lazy_new(mrb, buf, inner_offset, sharedrefs);
          mrb_ary_push(mrb, sharedrefs, lazy);
        } else {
          mrb_raise(mrb, E_RUNTIME_ERROR, "CBOR internal error: sharedrefs is not a array");
        }
      }
      skip_cbor(mrb, r, buf, sharedrefs);
      break;
    }

    case 7: {
      if (info < 24) break;
      switch (info) {
        case 24: if (likely(r->p < r->end)) { r->p++; break; }
                 else mrb_raise(mrb, E_RANGE_ERROR, "simple value out of bounds");
        case 25: if (likely((r->end - r->p) >= 2)) { r->p += 2; break; }
                 else mrb_raise(mrb, E_RANGE_ERROR, "float16 out of bounds");
        case 26: if (likely((r->end - r->p) >= 4)) { r->p += 4; break; }
                 else mrb_raise(mrb, E_RANGE_ERROR, "float32 out of bounds");
        case 27: if (likely((r->end - r->p) >= 8)) { r->p += 8; break; }
                 else mrb_raise(mrb, E_RANGE_ERROR, "float64 out of bounds");
        case 31: mrb_raise(mrb, E_NOTIMP_ERROR, "indefinite-length items not supported");
      }
      break;
    }

    default:
      mrb_raisef(mrb, E_NOTIMP_ERROR, "Not implemented CBOR major type '%d'", major);
  }

  r->depth--;
}

static mrb_bool
skip_cbor_try(mrb_state *mrb, Reader *r)
{
  if (unlikely(r->p >= r->end)) return FALSE;

  reader_check_depth(mrb, r);
  r->depth++;

  uint8_t b     = *r->p++;
  uint8_t major = b >> 5;
  uint8_t info  = b & 0x1F;
  mrb_bool ok   = TRUE;

  switch (major) {
    case 0: case 1:
      if (info >= 24) {
        if      (unlikely(info == 24 && r->p >= r->end))          ok = FALSE;
        else if (unlikely(info == 25 && (r->end - r->p) < 2))     ok = FALSE;
        else if (unlikely(info == 26 && (r->end - r->p) < 4))     ok = FALSE;
        else if (unlikely(info == 27 && (r->end - r->p) < 8))     ok = FALSE;
        else { mrb_value lv = read_cbor_uint(mrb, r, info); if (!mrb_integer_p(lv)) ok = FALSE; }
      }
      break;

    case 2: case 3: {
      if      (unlikely(info == 24 && r->p >= r->end))          { ok = FALSE; break; }
      if      (unlikely(info == 25 && (r->end - r->p) < 2))     { ok = FALSE; break; }
      if      (unlikely(info == 26 && (r->end - r->p) < 4))     { ok = FALSE; break; }
      if      (unlikely(info == 27 && (r->end - r->p) < 8))     { ok = FALSE; break; }
      mrb_value lv = read_cbor_uint(mrb, r, info);
      if (!mrb_integer_p(lv)) { ok = FALSE; break; }
      mrb_int len = mrb_integer(lv);
      if (unlikely(len < 0 || (mrb_int)(r->end - r->p) < len)) { ok = FALSE; break; }
      r->p += len;
      break;
    }

    case 4: {
      if      (unlikely(info == 24 && r->p >= r->end))          { ok = FALSE; break; }
      if      (unlikely(info == 25 && (r->end - r->p) < 2))     { ok = FALSE; break; }
      if      (unlikely(info == 26 && (r->end - r->p) < 4))     { ok = FALSE; break; }
      if      (unlikely(info == 27 && (r->end - r->p) < 8))     { ok = FALSE; break; }
      mrb_value lv = read_cbor_uint(mrb, r, info);
      if (!mrb_integer_p(lv)) { ok = FALSE; break; }
      mrb_int len = mrb_integer(lv);
      if (unlikely(len < 0)) { ok = FALSE; break; }
      for (mrb_int i = 0; i < len; i++) {
        if (!skip_cbor_try(mrb, r)) { ok = FALSE; break; }
      }
      break;
    }

    case 5: {
      if      (unlikely(info == 24 && r->p >= r->end))          { ok = FALSE; break; }
      if      (unlikely(info == 25 && (r->end - r->p) < 2))     { ok = FALSE; break; }
      if      (unlikely(info == 26 && (r->end - r->p) < 4))     { ok = FALSE; break; }
      if      (unlikely(info == 27 && (r->end - r->p) < 8))     { ok = FALSE; break; }
      mrb_value lv = read_cbor_uint(mrb, r, info);
      if (!mrb_integer_p(lv)) { ok = FALSE; break; }
      mrb_int len = mrb_integer(lv);
      if (unlikely(len < 0)) { ok = FALSE; break; }
      for (mrb_int i = 0; i < len; i++) {
        if (!skip_cbor_try(mrb, r)) { ok = FALSE; break; }
        if (!skip_cbor_try(mrb, r)) { ok = FALSE; break; }
      }
      break;
    }

    case 6: {
      if      (unlikely(info == 24 && r->p >= r->end))          { ok = FALSE; break; }
      if      (unlikely(info == 25 && (r->end - r->p) < 2))     { ok = FALSE; break; }
      if      (unlikely(info == 26 && (r->end - r->p) < 4))     { ok = FALSE; break; }
      if      (unlikely(info == 27 && (r->end - r->p) < 8))     { ok = FALSE; break; }
      mrb_value tag = read_cbor_uint(mrb, r, info);
      if (!mrb_integer_p(tag)) { ok = FALSE; break; }
      if (!skip_cbor_try(mrb, r)) ok = FALSE;
      break;
    }

    case 7: {
      if (info < 24) break;
      switch (info) {
        case 24: if (unlikely(r->p >= r->end)) ok = FALSE; else r->p++; break;
        case 25: if (unlikely((r->end-r->p)<2)) ok = FALSE; else r->p+=2; break;
        case 26: if (unlikely((r->end-r->p)<4)) ok = FALSE; else r->p+=4; break;
        case 27: if (unlikely((r->end-r->p)<8)) ok = FALSE; else r->p+=8; break;
        case 31: mrb_raise(mrb, E_NOTIMP_ERROR, "indefinite-length items not supported"); ok = FALSE; break;
        default: break;
      }
      break;
    }

    default:
      mrb_raisef(mrb, E_NOTIMP_ERROR, "Not implemented CBOR major type '%d'", major);
      ok = FALSE;
  }

  r->depth--;
  return ok;
}

static mrb_value
cbor_doc_end(mrb_state *mrb, const uint8_t *buf, size_t buf_len, mrb_int offset)
{
  if (unlikely(offset < 0 || (size_t)offset >= buf_len)) return mrb_nil_value();

  Reader r;
  r.base  = buf;
  r.p     = buf + offset;
  r.end   = buf + buf_len;
  r.depth = 0;

  if (unlikely(r.p >= r.end)) return mrb_nil_value();
  if (!skip_cbor_try(mrb, &r)) return mrb_nil_value();

  return mrb_convert_ptrdiff(mrb, (r.p - buf));
}

/* Lazy#value */
static mrb_value cbor_lazy_value_r(mrb_state *mrb, mrb_value self, mrb_int depth);

static mrb_value
cbor_lazy_value(mrb_state *mrb, mrb_value self)
{
  return cbor_lazy_value_r(mrb, self, 0);
}

static mrb_value
cbor_lazy_value_r(mrb_state *mrb, mrb_value self, mrb_int depth)
{
  if (unlikely(depth >= CBOR_MAX_DEPTH))
    mrb_raise(mrb, E_RUNTIME_ERROR, "CBOR nesting depth exceeded");

  mrb_value vcache = mrb_iv_get(mrb, self, MRB_SYM(vcache));
  if (!mrb_undef_p(vcache)) return vcache;

  cbor_lazy_t *p = mrb_data_get_ptr(mrb, self, &cbor_lazy_type);
  const uint8_t *base  = (const uint8_t*)RSTRING_PTR(p->buf);
  size_t total_len     = (size_t)RSTRING_LEN(p->buf);
  mrb_value sharedrefs = mrb_iv_get(mrb, self, MRB_SYM(sharedrefs));

  if (likely((size_t)p->offset < total_len)) {
    Reader r;
    r.base = base; r.p = base + p->offset; r.end = base + total_len; r.depth = depth;

    mrb_value value = decode_value(mrb, &r, p->buf, sharedrefs);
    if (mrb_data_check_get_ptr(mrb, value, &cbor_lazy_type)) {
      value = cbor_lazy_value_r(mrb, value, r.depth + 1);
    }
    mrb_iv_set(mrb, self, MRB_SYM(vcache), value);
    return value;
  } else {
    mrb_raise(mrb, E_RANGE_ERROR, "lazy offset out of bounds");
  }
  return mrb_undef_value();
}

static mrb_value
lazy_fetch_from_cache(mrb_state *mrb, mrb_value self, mrb_value key)
{
  mrb_value kcache = mrb_iv_get(mrb, self, MRB_SYM(kcache));
  if (likely(mrb_hash_p(kcache)))
    return mrb_hash_fetch(mrb, kcache, key, mrb_undef_value());
  mrb_raise(mrb, E_RUNTIME_ERROR, "CBOR internal error: kcache corrupted");
  return mrb_undef_value();
}

static void
lazy_reader_init(mrb_state *mrb, Reader *r, cbor_lazy_t *p)
{
  const uint8_t *base = (const uint8_t*)RSTRING_PTR(p->buf);
  size_t total_len    = (size_t)RSTRING_LEN(p->buf);
  if (likely((size_t)p->offset < total_len)) {
    r->base = base; r->p = base + p->offset; r->end = base + total_len; r->depth = 0;
  } else {
    mrb_raise(mrb, E_RANGE_ERROR, "lazy offset out of bounds");
  }
}

static mrb_value
lazy_aref_array(mrb_state *mrb, Reader *r, mrb_value key,
                mrb_value self, cbor_lazy_t *p, mrb_value sharedrefs)
{
  mrb_value kcache = mrb_iv_get(mrb, self, MRB_SYM(kcache));
  if (likely(mrb_hash_p(kcache))) {
    mrb_int idx = mrb_integer(mrb_ensure_int_type(mrb, key));
    mrb_int len = cbor_value_to_len(mrb, read_cbor_uint(mrb, r, r->info));

    if (idx < 0) idx += len;
    if (unlikely(idx >= len || idx < 0))
      mrb_raisef(mrb, E_INDEX_ERROR,
        "index %d outside of array bounds: -%d...%d", idx, len, len);

    for (mrb_int i = 0; i < idx; i++) skip_cbor(mrb, r, p->buf, sharedrefs);

    mrb_int elem_offset = cbor_pdiff(mrb, r->p, r->base);
    mrb_value new_lazy = cbor_lazy_new(mrb, p->buf, elem_offset, sharedrefs);
    mrb_hash_set(mrb, kcache, key, new_lazy);
    return new_lazy;
  } else {
    mrb_raise(mrb, E_TYPE_ERROR, "kcache is not a hash");
  }
  return mrb_undef_value();
}

static mrb_value
lazy_aref_map(mrb_state *mrb, Reader *r, mrb_value key,
              mrb_value self, cbor_lazy_t *p, mrb_value sharedrefs)
{
  mrb_value kcache = mrb_iv_get(mrb, self, MRB_SYM(kcache));
  if (likely(mrb_hash_p(kcache))) {
    mrb_int pairs = cbor_value_to_len(mrb, read_cbor_uint(mrb, r, r->info));
    const mrb_bool key_is_str = mrb_string_p(key);

    for (mrb_int i = 0; i < pairs; i++) {
      mrb_bool match;
      uint8_t kb    = reader_read8(mrb, r);
      uint8_t kmaj  = (uint8_t)(kb >> 5);
      uint8_t kinfo = (uint8_t)(kb & 0x1F);

      if (key_is_str && (kmaj == 2 || kmaj == 3)) {
        mrb_int klen = cbor_value_to_len(mrb, read_cbor_uint(mrb, r, kinfo));
        reader_advance_checked(mrb, r, klen);
        match = (klen == RSTRING_LEN(key) &&
                 memcmp(r->p - klen, RSTRING_PTR(key), (size_t)klen) == 0);
      } else {
        r->p--;
        match = mrb_equal(mrb, decode_value(mrb, r, p->buf, sharedrefs), key);
      }

      if (match) {
        mrb_int value_offset = cbor_pdiff(mrb, r->p, r->base);
        mrb_value lazy_new = cbor_lazy_new(mrb, p->buf, value_offset, sharedrefs);
        mrb_hash_set(mrb, kcache, key, lazy_new);
        return lazy_new;
      }
      skip_cbor(mrb, r, p->buf, sharedrefs);
    }

    mrb_raisef(mrb, E_KEY_ERROR, "key not found: \"%v\"", key);
  } else {
    mrb_raise(mrb, E_RUNTIME_ERROR, "CBOR internal error: kcache corrupted");
  }
  return mrb_undef_value();
}

static uint8_t
lazy_resolve_tags(mrb_state *mrb, Reader *r, mrb_value sharedrefs,
                  mrb_value *resolved_out)
{
  *resolved_out = mrb_undef_value();
  while (r->major == 6) {
    mrb_value tag = read_cbor_uint(mrb, r, r->info);
    if (mrb_cmp(mrb, tag, mrb_fixnum_value(29)) == 0) {
      *resolved_out = decode_tag_sharedref(mrb, r, sharedrefs);
      return 0xFF;
    }
    reader_read_header(mrb, r);
  }
  return r->major;
}

static mrb_value cbor_lazy_aref_r(mrb_state *mrb, mrb_value self, mrb_value key, mrb_int depth);

static mrb_value
cbor_lazy_aref(mrb_state *mrb, mrb_value self, mrb_value key)
{
  return cbor_lazy_aref_r(mrb, self, key, 0);
}

static mrb_value
cbor_lazy_aref_r(mrb_state *mrb, mrb_value self, mrb_value key, mrb_int depth)
{
  if (unlikely(depth >= CBOR_MAX_DEPTH))
    mrb_raise(mrb, E_RUNTIME_ERROR, "CBOR nesting depth exceeded");

  mrb_value cached = lazy_fetch_from_cache(mrb, self, key);
  if (!mrb_undef_p(cached)) return cached;

  cbor_lazy_t *p = mrb_data_get_ptr(mrb, self, &cbor_lazy_type);
  Reader r;
  lazy_reader_init(mrb, &r, p);
  reader_read_header(mrb, &r);

  mrb_value sharedrefs = mrb_iv_get(mrb, self, MRB_SYM(sharedrefs));
  if (likely(mrb_array_p(sharedrefs))) {
    mrb_value resolved;
    uint8_t major = lazy_resolve_tags(mrb, &r, sharedrefs, &resolved);
    switch (major) {
      case 4: return lazy_aref_array(mrb, &r, key, self, p, sharedrefs);
      case 5: return lazy_aref_map(mrb, &r, key, self, p, sharedrefs);
      case 0xFF:
        if (mrb_data_check_get_ptr(mrb, resolved, &cbor_lazy_type))
          return cbor_lazy_aref_r(mrb, resolved, key, depth + 1);
        /* fall through */
      default:
        mrb_raise(mrb, E_TYPE_ERROR, "not indexable");
    }
  } else {
    mrb_raise(mrb, E_RUNTIME_ERROR, "CBOR internal error: sharedrefs corrupted");
  }
  return mrb_undef_value();
}

static mrb_value
cbor_lazy_aref_m(mrb_state *mrb, mrb_value self)
{
  mrb_value key;
  mrb_get_args(mrb, "o", &key);
  return cbor_lazy_aref(mrb, self, key);
}

static mrb_value
cbor_decode_rb_lazy(mrb_state *mrb, mrb_value self)
{
  mrb_value buf;
  mrb_get_args(mrb, "S", &buf);
  mrb_value owned_buf   = mrb_str_byte_subseq(mrb, buf, 0, RSTRING_LEN(buf));
  mrb_value sharedrefs  = mrb_ary_new(mrb);
  return cbor_lazy_new(mrb, owned_buf, 0, sharedrefs);
}

static mrb_value
cbor_lazy_dig(mrb_state *mrb, mrb_value self)
{
  mrb_value *keys;
  mrb_int    nkeys;
  mrb_get_args(mrb, "*", &keys, &nkeys);

  if (nkeys == 0) return self;

  mrb_value current = self;

  for (mrb_int ki = 0; ki < nkeys; ki++) {
    if (mrb_nil_p(current)) return mrb_nil_value();

    cbor_lazy_t *p = mrb_data_get_ptr(mrb, current, &cbor_lazy_type);
    mrb_value key  = keys[ki];

    mrb_value kcache = mrb_iv_get(mrb, current, MRB_SYM(kcache));
    if (likely(mrb_hash_p(kcache))) {
      mrb_value cached = mrb_hash_fetch(mrb, kcache, key, mrb_undef_value());
      if (!mrb_undef_p(cached)) { current = cached; continue; }
    } else {
      mrb_raise(mrb, E_RUNTIME_ERROR, "CBOR internal error: kcache corrupted");
    }

    const uint8_t *base    = (const uint8_t*)RSTRING_PTR(p->buf);
    size_t         total   = (size_t)RSTRING_LEN(p->buf);
    mrb_value      sharedrefs = mrb_iv_get(mrb, current, MRB_SYM(sharedrefs));

    if (unlikely((size_t)p->offset >= total))
      mrb_raise(mrb, E_RUNTIME_ERROR, "lazy offset out of bounds");

    Reader r;
    r.base = base; r.p = base + p->offset; r.end = base + total; r.depth = 0;
    reader_read_header(mrb, &r);

    mrb_value dig_resolved;
    uint8_t major = lazy_resolve_tags(mrb, &r, sharedrefs, &dig_resolved);

    if (major == 0xFF) {
      if (mrb_data_check_get_ptr(mrb, dig_resolved, &cbor_lazy_type)) {
        current = cbor_lazy_aref(mrb, dig_resolved, key);
        continue;
      }
      mrb_raise(mrb, E_TYPE_ERROR, "CBOR::Lazy#dig: sharedref target is not indexable");
    }

    mrb_value result;

    switch (major) {
      case 4: {
        mrb_int idx = mrb_integer(mrb_ensure_int_type(mrb, key));
        mrb_int len = cbor_value_to_len(mrb, read_cbor_uint(mrb, &r, r.info));
        if (idx < 0) idx += len;
        if (idx < 0 || idx >= len) { current = mrb_nil_value(); continue; }
        for (mrb_int i = 0; i < idx; i++) skip_cbor(mrb, &r, current, sharedrefs);
        mrb_int elem_off = cbor_pdiff(mrb, r.p, base);
        result = cbor_lazy_new(mrb, p->buf, elem_off, sharedrefs);
        mrb_hash_set(mrb, kcache, key, result);
      } break;

      case 5: {
        mrb_int pairs    = cbor_value_to_len(mrb, read_cbor_uint(mrb, &r, r.info));
        const mrb_bool key_is_str = mrb_string_p(key);
        mrb_bool found      = FALSE;

        for (mrb_int i = 0; i < pairs; i++) {
          mrb_bool match;
          uint8_t kb    = reader_read8(mrb, &r);
          uint8_t kmaj  = kb >> 5;
          uint8_t kinfo = kb & 0x1F;

          if (key_is_str && (kmaj == 2 || kmaj == 3)) {
            mrb_int klen = cbor_value_to_len(mrb, read_cbor_uint(mrb, &r, kinfo));
            reader_advance_checked(mrb, &r, klen);
            match = (klen == RSTRING_LEN(key) &&
                     memcmp(r.p - klen, RSTRING_PTR(key), (size_t)klen) == 0);
          } else {
            r.p--;
            match = mrb_equal(mrb, decode_value(mrb, &r, p->buf, sharedrefs), key);
          }

          if (match) {
            mrb_int val_off = cbor_pdiff(mrb, r.p, base);
            result = cbor_lazy_new(mrb, p->buf, val_off, sharedrefs);
            mrb_hash_set(mrb, kcache, key, result);
            found = TRUE;
            break;
          }
          skip_cbor(mrb, &r, current, sharedrefs);
        }

        if (!found) { current = mrb_nil_value(); continue; }
      } break;

      default:
        mrb_raise(mrb, E_TYPE_ERROR, "CBOR::Lazy#dig: not indexable");
        return mrb_undef_value();
    }

    current = result;
  }

  return current;
}

static mrb_value cbor_no_symbols(mrb_state *mrb, mrb_value self)
  { cbor_set_sym_strategy(mrb, 0); return self; }

static mrb_value cbor_symbols_as_string(mrb_state *mrb, mrb_value self)
  { cbor_set_sym_strategy(mrb, 1); return self; }

static mrb_value
cbor_symbols_as_uint32(mrb_state *mrb, mrb_value self)
{
#ifdef MRB_NO_PRESYM
  mrb_raise(mrb, E_NOTIMP_ERROR,
    "mruby was compiled without presym, symbols_as_uint32 is not available.");
#else
  cbor_set_sym_strategy(mrb, 2);
#endif
  return self;
}

static void
cbor_register_tag_impl(mrb_state *mrb, mrb_value tag_v, mrb_value klass)
{
  if (!mrb_integer_p(tag_v))
    mrb_raise(mrb, E_TYPE_ERROR, "tag must be an integer");

  static const int reserved[] = { 2, 3, 28, 29, 39 };
  for (uint8_t i = 0; i < sizeof(reserved) / sizeof(reserved[0]); i++) {
    if (unlikely(mrb_cmp(mrb, tag_v, mrb_fixnum_value(reserved[i])) == 0))
      mrb_raisef(mrb, E_ARGUMENT_ERROR,
        "tag %v is reserved for internal CBOR use", tag_v);
  }
  if (unlikely(mrb_integer_p(tag_v) && (uint64_t)mrb_integer(tag_v) == CBOR_TAG_CLASS))
    mrb_raise(mrb, E_ARGUMENT_ERROR, "tag 49999 is reserved for internal CBOR use");

  {
    struct RClass *kp = mrb_class_ptr(klass);
    if (unlikely(MRB_INSTANCE_TT(kp) != MRB_TT_OBJECT))
      mrb_raise(mrb, E_TYPE_ERROR,
        "registered tag class must be a plain Ruby class (not CDATA or other native type)");
    if (unlikely(kp == mrb->string_class  || kp == mrb->array_class   ||
                 kp == mrb->hash_class    || kp == mrb->float_class   ||
                 kp == mrb->integer_class || kp == mrb->true_class    ||
                 kp == mrb->false_class   || kp == mrb->nil_class     ||
                 kp == mrb->symbol_class  || kp == mrb->eException_class))
      mrb_raise(mrb, E_TYPE_ERROR, "cannot register built-in class as CBOR tag");
  }

  mrb_hash_set(mrb, cbor_tag_registry(mrb),     tag_v, klass);
  mrb_hash_set(mrb, cbor_tag_rev_registry(mrb), klass, tag_v);
}

static mrb_value
cbor_register_tag_rb(mrb_state *mrb, mrb_value self)
{
  mrb_value tag_v;
  mrb_value klass;
  mrb_get_args(mrb, "oC", &tag_v, &klass);
  (void)self;
  cbor_register_tag_impl(mrb, tag_v, klass);
  return mrb_nil_value();
}

static mrb_value
cbor_register_tag_proc_rb(mrb_state *mrb, mrb_value self)
{
  mrb_value tag_v, encode_type, encode_prc, decode_type, decode_prc;
  mrb_get_args(mrb, "ooooo", &tag_v, &encode_type, &encode_prc,
                                     &decode_type, &decode_prc);
  (void)self;

  if (!mrb_integer_p(tag_v))
    mrb_raise(mrb, E_TYPE_ERROR, "tag must be an integer");
  if (!mrb_proc_p(encode_prc) || !mrb_proc_p(decode_prc))
    mrb_raise(mrb, E_TYPE_ERROR, "encode and decode must be Procs");

  static const int reserved[] = { 2, 3, 28, 29, 39 };
  for (uint8_t i = 0; i < sizeof(reserved) / sizeof(reserved[0]); i++) {
    if (unlikely(mrb_cmp(mrb, tag_v, mrb_fixnum_value(reserved[i])) == 0))
      mrb_raisef(mrb, E_ARGUMENT_ERROR,
        "tag %v is reserved for internal CBOR use", tag_v);
  }
  if (unlikely((uint64_t)mrb_integer(tag_v) == CBOR_TAG_CLASS))
    mrb_raise(mrb, E_ARGUMENT_ERROR, "tag 49999 is reserved for internal CBOR use");

  if (mrb_class_p(encode_type)) {
    struct RClass *ep = mrb_class_ptr(encode_type);
    if (ep == mrb->string_class  || ep == mrb->array_class  ||
        ep == mrb->hash_class    || ep == mrb->float_class  ||
        ep == mrb->integer_class || ep == mrb->true_class   ||
        ep == mrb->false_class   || ep == mrb->nil_class    ||
        ep == mrb->symbol_class  || ep == mrb->class_class  ||
        ep == mrb->module_class)
      mrb_raise(mrb, E_TYPE_ERROR,
        "cannot register proc tag for a natively-encoded type");
  }

  mrb_value decode_type_ary = mrb_ary_new_from_values(mrb, 1, &decode_type);

  mrb_value fwd_entry = mrb_hash_new_capa(mrb, 2);
  mrb_hash_set(mrb, fwd_entry, mrb_symbol_value(MRB_SYM(decode_type)), decode_type_ary);
  mrb_hash_set(mrb, fwd_entry, mrb_symbol_value(MRB_SYM(decode_proc)), decode_prc);
  mrb_hash_set(mrb, cbor_proc_tag_registry(mrb), tag_v, fwd_entry);

  mrb_value rev_entry = mrb_hash_new_capa(mrb, 2);
  mrb_hash_set(mrb, rev_entry, mrb_symbol_value(MRB_SYM(tag)),         tag_v);
  mrb_hash_set(mrb, rev_entry, mrb_symbol_value(MRB_SYM(encode_proc)), encode_prc);
  mrb_hash_set(mrb, cbor_proc_tag_rev_registry(mrb), encode_type, rev_entry);

  return mrb_nil_value();
}

static mrb_value
cbor_encode_rb(mrb_state *mrb, mrb_value self)
{
  mrb_value obj;
  (void)self;

  mrb_kwargs kwargs;
  mrb_sym    kw_keys[1]   = { MRB_SYM(sharedrefs) };
  mrb_value  kw_values[1] = { mrb_undef_value() };
  kwargs.num      = 1;
  kwargs.required = 0;
  kwargs.table    = kw_keys;
  kwargs.values   = kw_values;
  kwargs.rest     = NULL;

  mrb_get_args(mrb, "o:", &obj, &kwargs);

  CborWriter w;
  cbor_writer_init(&w, mrb);

  if (!mrb_undef_p(kw_values[0]) && mrb_bool(kw_values[0])) {
    w.seen = mrb_hash_new(mrb);
    mrb_gc_register(mrb, w.seen);
  }

  encode_value(&w, obj);
  return cbor_writer_finish(&w);
}

static mrb_value
cbor_decode_rb(mrb_state *mrb, mrb_value self)
{
  mrb_value src;
  Reader r;
  (void)self;

  mrb_get_args(mrb, "S", &src);
  src = mrb_str_byte_subseq(mrb, src, 0, RSTRING_LEN(src));
  reader_init(&r, (const uint8_t*)RSTRING_PTR(src), (size_t)RSTRING_LEN(src));
  mrb_value sharedrefs = mrb_ary_new(mrb);
  return decode_value(mrb, &r, src, sharedrefs);
}

static mrb_value
cbor_doc_end_rb(mrb_state *mrb, mrb_value self)
{
  mrb_value buf;
  mrb_int offset = 0;
  (void)self;

  mrb_get_args(mrb, "S|i", &buf, &offset);
  return cbor_doc_end(mrb,
    (const uint8_t*)RSTRING_PTR(buf),
    (size_t)RSTRING_LEN(buf),
    offset);
}

MRB_BEGIN_DECL

MRB_API mrb_value
mrb_cbor_encode(mrb_state *mrb, mrb_value obj)
{
  CborWriter w;
  cbor_writer_init(&w, mrb);
  encode_value(&w, obj);
  return cbor_writer_finish(&w);
}

MRB_API mrb_value
mrb_cbor_encode_sharedrefs(mrb_state *mrb, mrb_value obj)
{
  CborWriter w;
  cbor_writer_init(&w, mrb);
  w.seen = mrb_hash_new(mrb);
  mrb_gc_register(mrb, w.seen);
  encode_value(&w, obj);
  return cbor_writer_finish(&w);
}

MRB_API mrb_value
mrb_cbor_decode(mrb_state *mrb, mrb_value buf)
{
  if (likely(mrb_string_p(buf))) {
    mrb_value owned = mrb_str_byte_subseq(mrb, buf, 0, RSTRING_LEN(buf));
    Reader r;
    reader_init(&r, (const uint8_t*)RSTRING_PTR(owned), (size_t)RSTRING_LEN(owned));
    mrb_value sharedrefs = mrb_ary_new(mrb);
    return decode_value(mrb, &r, owned, sharedrefs);
  }
  mrb_raise(mrb, E_TYPE_ERROR, "buf is not a String");
}

MRB_API mrb_value
mrb_cbor_decode_lazy(mrb_state *mrb, mrb_value buf)
{
  if (likely(mrb_string_p(buf))) {
    mrb_value owned      = mrb_str_byte_subseq(mrb, buf, 0, RSTRING_LEN(buf));
    mrb_value sharedrefs = mrb_ary_new(mrb);
    return cbor_lazy_new(mrb, owned, 0, sharedrefs);
  }
  mrb_raise(mrb, E_TYPE_ERROR, "buf is not a String");
}

MRB_API mrb_value
mrb_cbor_lazy_value(mrb_state *mrb, mrb_value lazy)
{
  mrb_data_check_type(mrb, lazy, &cbor_lazy_type);
  return cbor_lazy_value(mrb, lazy);
}

MRB_API mrb_value
mrb_cbor_doc_end(mrb_state *mrb, mrb_value buf, mrb_int offset)
{
  if (likely(mrb_string_p(buf))) {
    return cbor_doc_end(mrb,
      (const uint8_t*)RSTRING_PTR(buf),
      (size_t)RSTRING_LEN(buf),
      offset);
  }
  mrb_raise(mrb, E_TYPE_ERROR, "buf is not a String");
}

MRB_API mrb_value
mrb_cbor_encode_fast(mrb_state *mrb, mrb_value obj)
{
  CborWriter w;
  cbor_writer_init(&w, mrb);
  encode_value_fast(&w, obj);
  return cbor_writer_finish(&w);
}

MRB_API mrb_value
mrb_cbor_decode_fast(mrb_state *mrb, mrb_value buf)
{
  if (likely(mrb_string_p(buf))) {
    mrb_value owned = mrb_str_byte_subseq(mrb, buf, 0, RSTRING_LEN(buf));
    Reader r;
    reader_init(&r, (const uint8_t*)RSTRING_PTR(owned), (size_t)RSTRING_LEN(owned));
    return decode_value_fast(mrb, &r, owned);
  }
  mrb_raise(mrb, E_TYPE_ERROR, "buf is not a String");
}

MRB_API void
mrb_cbor_register_tag(mrb_state *mrb, uint64_t tag_num, struct RClass *klass)
{
  cbor_register_tag_impl(mrb, mrb_convert_uint64(mrb, tag_num), mrb_obj_value(klass));
}

MRB_API void
mrb_mruby_cbor_gem_init(mrb_state* mrb)
{
  struct RClass* cbor = mrb_define_module_id(mrb, MRB_SYM(CBOR));
  mrb_define_module_function_id(mrb, cbor, MRB_SYM(no_symbols),       cbor_no_symbols,       MRB_ARGS_NONE());
  mrb_define_module_function_id(mrb, cbor, MRB_SYM(symbols_as_uint32),cbor_symbols_as_uint32,MRB_ARGS_NONE());
  mrb_define_module_function_id(mrb, cbor, MRB_SYM(symbols_as_string),cbor_symbols_as_string,MRB_ARGS_NONE());
  mrb_define_module_function_id(mrb, cbor, MRB_SYM(decode),           cbor_decode_rb,        MRB_ARGS_REQ(1));
  mrb_define_module_function_id(mrb, cbor, MRB_SYM(register_tag),      cbor_register_tag_rb,      MRB_ARGS_REQ(2));
  mrb_define_module_function_id(mrb, cbor, MRB_SYM(register_tag_proc), cbor_register_tag_proc_rb, MRB_ARGS_REQ(5));
  mrb_define_module_function_id(mrb, cbor, MRB_SYM(encode),           cbor_encode_rb,        MRB_ARGS_REQ(1)|MRB_ARGS_KEY(0,1));
  mrb_define_module_function_id(mrb, cbor, MRB_SYM(doc_end),          cbor_doc_end_rb,       MRB_ARGS_ARG(1,1));
  mrb_define_module_function_id(mrb, cbor, MRB_SYM(decode_lazy),      cbor_decode_rb_lazy,   MRB_ARGS_REQ(1));
  mrb_define_module_function_id(mrb, cbor, MRB_SYM(encode_fast),      cbor_encode_fast_rb,   MRB_ARGS_REQ(1));
  mrb_define_module_function_id(mrb, cbor, MRB_SYM(decode_fast),      cbor_decode_fast_rb,   MRB_ARGS_REQ(1));

  struct RClass *lazy = mrb_define_class_under_id(mrb, cbor, MRB_SYM(Lazy), mrb->object_class);
  MRB_SET_INSTANCE_TT(lazy, MRB_TT_CDATA);
  mrb_undef_method_id(mrb, lazy, MRB_SYM(initialize));
  mrb_define_method_id(mrb, lazy, MRB_OPSYM(aref), cbor_lazy_aref_m, MRB_ARGS_REQ(1));
  mrb_define_method_id(mrb, lazy, MRB_SYM(value),  cbor_lazy_value,  MRB_ARGS_NONE());
  mrb_define_method_id(mrb, lazy, MRB_SYM(dig),    cbor_lazy_dig,    MRB_ARGS_ANY());
}

MRB_API void
mrb_mruby_cbor_gem_final(mrb_state* mrb)
{
  (void)mrb;
}

MRB_END_DECL