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

#include <stdlib.h>
#include <stdint.h>
#include <stddef.h>
#include <string.h>
#include <stdbool.h>

/* Configurable CBOR recursion depth limits */
#ifndef CBOR_MAX_DEPTH
  #if defined(MRB_PROFILE_MAIN) || defined(MRB_PROFILE_HIGH)
    #define CBOR_MAX_DEPTH 512
  #elif defined(MRB_PROFILE_BASELINE)
    #define CBOR_MAX_DEPTH 64
  #else
    #define CBOR_MAX_DEPTH 32
  #endif
#endif

typedef struct {
  const uint8_t* base;
  const uint8_t* p;
  const uint8_t* end;

  uint8_t major;
  uint8_t info;

  /* Recursion depth counter to prevent stack overflow */
  mrb_int depth;
} Reader;

static uint8_t
reader_read8(mrb_state* mrb, Reader* r)
{
  if (likely(r->p < r->end)) return *r->p++;
  mrb_raise(mrb, E_RUNTIME_ERROR, "unexpected end of buffer");
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

/* Check recursion depth before entering recursive functions */
static inline void
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

  /* Stack-Buffer (SBO) */
  uint8_t stack_buf[CBOR_SBO_STACK_CAP];
  size_t  stack_len;

  /* Heap-Buffer (Ruby-String) */
  mrb_value heap_str;  /* mrb_undef_value() solange nur Stack */
  char    *heap_ptr;
  size_t   heap_len;
  size_t   heap_capa;
  mrb_int  arena_index;

  /* Shared references (Tag 28/29):
     mrb_undef_value() = disabled
     mrb_hash         = obj -> share_idx mapping */
  mrb_value seen;
} CborWriter;

/* Forward declarations */
static mrb_value cbor_tag_registry(mrb_state *mrb);
static mrb_value cbor_tag_rev_registry(mrb_state *mrb);
static void      encode_registered_tag(CborWriter *w, mrb_value obj, mrb_int tag_num);
static mrb_value decode_registered_tag(mrb_state *mrb, Reader *r, mrb_value src, mrb_value sharedrefs, mrb_value klass);

/* Safe pointer-diff -> mrb_int. Raises if negative or > MRB_INT_MAX. */
static mrb_int
cbor_pdiff(mrb_state *mrb, const uint8_t *p, const uint8_t *base)
{
  ptrdiff_t d = p - base;
  if (likely(d >= 0 && d <= (ptrdiff_t)MRB_INT_MAX))
    return (mrb_int)d;
  mrb_raise(mrb, E_RANGE_ERROR, "CBOR offset out of range");
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

/*
 * Read a CBOR unsigned integer (additional info already consumed as `info`)
 * and return it as mrb_value.  Handles info < 24; reads extra bytes
 * for info 24..27.  Raises on indefinite-length (31) or bogus info.
 *
 * Replaces the old Num struct + read_num + read_len pair.
 */
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
        mrb_raise(mrb, E_RANGE_ERROR, "integer out of range");
    #else
        return mrb_convert_uint8(mrb, u);
    #endif
      }
      mrb_raise(mrb, E_RANGE_ERROR, "invalid uint8");
      break;

    case 25:
      if (likely(end - p >= 2)) {
        r->p += 2;
        uint16_t u = ((uint16_t)p[0] << 8) | p[1];
    #ifndef MRB_USE_BIGINT
        if (likely((uint64_t)u <= (uint64_t)MRB_INT_MAX + 1))
          return mrb_convert_uint16(mrb, u);
        mrb_raise(mrb, E_RANGE_ERROR, "integer out of range");
    #else
        return mrb_convert_uint16(mrb, u);
    #endif
      }
      mrb_raise(mrb, E_RANGE_ERROR, "invalid uint16");
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
        mrb_raise(mrb, E_RANGE_ERROR, "integer out of range");
    #else
        return mrb_convert_uint32(mrb, u);
    #endif
      }
      mrb_raise(mrb, E_RANGE_ERROR, "invalid uint32");
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
        mrb_raise(mrb, E_RANGE_ERROR, "integer out of range");
    #else
        return mrb_convert_uint64(mrb, u);
    #endif
      }
      mrb_raise(mrb, E_RANGE_ERROR, "invalid uint64");
      break;

    case 31:
      mrb_raise(mrb, E_NOTIMP_ERROR, "indefinite-length items not supported");
      break;
  }

  mrb_raisef(mrb, E_RUNTIME_ERROR, "invalid integer encoding: %d", info);
  return mrb_undef_value();
}

/*
 * Extract mrb_int from a CBOR length/count mrb_value for use as a C loop
 * bound, offset, or byte count.  Raises RangeError if the value is not a
 * fixnum (e.g. a Bigint that would never fit in an allocation) or negative.
 */
static mrb_int
cbor_value_to_len(mrb_state *mrb, mrb_value v)
{
  if (likely(mrb_integer_p(v))) {
    mrb_int n = mrb_integer(v);
    if (likely(n >= 0)) return n;
  }
  mrb_raise(mrb, E_RANGE_ERROR, "CBOR length out of range");
  return 0; /* unreachable */
}

// ============================================================================
// Length / bounds helpers
// ============================================================================

/*
 * Validate that `len` bytes are available starting at r->p and advance r->p.
 * Single chokepoint for all "skip N raw bytes" sites.
 */
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
static inline mrb_value
decode_unsigned(mrb_state* mrb, Reader* r, uint8_t info)
{
  return read_cbor_uint(mrb, r, info);
}

static mrb_value
decode_negative(mrb_state* mrb, Reader* r, uint8_t info)
{
  mrb_value n = read_cbor_uint(mrb, r, info);

  if (likely(mrb_integer_p(n))) {
    mrb_int v = mrb_integer(n);
    return mrb_convert_mrb_int(mrb, -1 - v);
  }

#ifdef MRB_USE_BIGINT
  else if (mrb_bigint_p(n)) {
    /* n is a Bigint: result = -(n + 1) */
    mrb_value np1 = mrb_bint_add(mrb, n, mrb_fixnum_value(1));
    return mrb_bint_neg(mrb, np1);
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
    mrb_raise(mrb, E_RUNTIME_ERROR, "string slice isn't utf8");
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
             uint8_t info, mrb_value shared, bool reg)
{
  mrb_value len_v = read_cbor_uint(mrb, r, info);
  mrb_int len = cbor_value_to_len(mrb, len_v);
  mrb_value ary = mrb_ary_new(mrb);

  if (reg) {
    mrb_ary_push(mrb, shared, ary);
  }

  for (mrb_int i = 0; i < len; i++) {
    mrb_value v = decode_value(mrb, r, src, shared);
    mrb_ary_push(mrb, ary, v);
  }

  return ary;
}

static mrb_value
decode_map(mrb_state* mrb, Reader* r, mrb_value src,
           uint8_t info, mrb_value shared, bool reg)
{
  mrb_value len_v = read_cbor_uint(mrb, r, info);
  mrb_int len = cbor_value_to_len(mrb, len_v);
  mrb_value hash = mrb_hash_new(mrb);

  if (reg) {
    mrb_ary_push(mrb, shared, hash);
  }

  for (mrb_int i = 0; i < len; i++) {
    mrb_value key = decode_value(mrb, r, src, shared);
    mrb_value val = decode_value(mrb, r, src, shared);
    mrb_hash_set(mrb, hash, key, val);
  }

  return hash;
}

static mrb_value
decode_null_with_skip(mrb_state *mrb, Reader *r, uint8_t info)
{
  if (info == 24) {
    reader_read8(mrb, r); /* payload ignorieren */
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
  mrb_float f;

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
        while ((mant & 0x0400u) == 0) {
          mant <<= 1;
          shift++;
        }
        mant &= 0x03FFu;
        uint32_t new_exp  = (uint32_t)(127 - 14 - shift) << 23;
        uint32_t new_frac = mant << 13;
        u = ((uint32_t)sign << 16) | new_exp | new_frac;
      }

      float f32;
      memcpy(&f32, &u, sizeof(float));
      f = (mrb_float)f32;
      break;
    }

    case 26: { /* Float32 */
      uint32_t u =
        ((uint32_t)reader_read8(mrb, r) << 24) |
        ((uint32_t)reader_read8(mrb, r) << 16) |
        ((uint32_t)reader_read8(mrb, r) << 8)  |
        ((uint32_t)reader_read8(mrb, r));

      float f32;
      memcpy(&f32, &u, sizeof(float));
      f = (mrb_float)f32;
      break;
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
      f = (mrb_float)f64;
      break;
    }

    default:
      mrb_raise(mrb, E_RUNTIME_ERROR, "invalid float encoding");
      f = 0;
  }

  return mrb_float_value(mrb, f);
}
#endif

#ifdef MRB_USE_BIGINT
static mrb_value
decode_tagged_bignum(mrb_state* mrb, Reader* r, mrb_value src, mrb_value tag)
{
  mrb_int idx = mrb_gc_arena_save(mrb);

  /* Read inner header */
  uint8_t b2 = reader_read8(mrb, r);
  uint8_t major2 = (uint8_t)(b2 >> 5);
  uint8_t info2  = (uint8_t)(b2 & 0x1F);

  if (likely(major2 == 2)) {
    mrb_value len_v = read_cbor_uint(mrb, r, info2);
    mrb_int len = cbor_value_to_len(mrb, len_v);

    if (likely(len > 0)) {
      ptrdiff_t off = r->p - r->base;
      if (likely(off >= 0)) {
        ensure_slice_bounds(mrb, src, (mrb_int)off, len);
        r->p += len;

        const uint8_t* buf = (const uint8_t*)RSTRING_PTR(src) + off;
        mrb_bool negative = (mrb_cmp(mrb, tag, mrb_fixnum_value(3)) == 0);

        const uint8_t* bigbuf = buf;

#ifndef MRB_ENDIAN_BIG
        if (likely(len > 1)) {
          uint8_t *tmp = mrb_alloca(mrb, len);
          memcpy(tmp, buf, len);
          for (mrb_int i = 0, j = len - 1; i < j; i++, j--) {
            uint8_t t = tmp[i];
            tmp[i] = tmp[j];
            tmp[j] = t;
          }
          bigbuf = tmp;
        }
#endif

        mrb_value n = mrb_bint_from_bytes(mrb, bigbuf, len);
        mrb_gc_arena_restore(mrb, idx);
        mrb_gc_protect(mrb, n);

        if (!negative)
          return n;

        if (mrb_integer_p(n)) {
          mrb_int v = mrb_integer(n);
          mrb_value ret = mrb_convert_mrb_int(mrb, -1 - v);
          mrb_gc_arena_restore(mrb, idx);
          mrb_gc_protect(mrb, ret);
          return ret;
        } else if (mrb_bigint_p(n)) {
          mrb_value one = mrb_fixnum_value(1);
          mrb_value n_plus_1 = mrb_bint_add(mrb, n, one);
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
      mrb_raise(mrb, E_RUNTIME_ERROR, "invalid bignum: zero length");
    }
  } else {
    mrb_raise(mrb, E_RUNTIME_ERROR, "invalid bignum payload");
  }

  return mrb_undef_value();
}
#endif

static mrb_value
decode_tag_sharedrefs(mrb_state* mrb, Reader* r,
                     mrb_value src, mrb_value sharedrefs_array)
{
  uint8_t nb = reader_read8(mrb, r);
  uint8_t major = nb >> 5;
  uint8_t info  = nb & 0x1F;

  switch (major) {
    case 4: return decode_array(mrb, r, src, info, sharedrefs_array, true);
    case 5: return decode_map(mrb, r, src, info, sharedrefs_array, true);
  }

  r->p--;
  mrb_value v = decode_value(mrb, r, src, sharedrefs_array);
  mrb_ary_push(mrb, sharedrefs_array, v);
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
    mrb_raise(mrb, E_TYPE_ERROR, "sharedrefs is not a array");
  }

  return mrb_undef_value();
}

/*
 * Symbol encoding strategy, stored and returned as mrb_value.
 * 0 = symbols as strings (default)
 * 1 = tag 39 + string
 * 2 = tag 39 + uint32 symbol ID
 */
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
    case 0:
      result = decode_unsigned(mrb, r, info);
      break;
    case 1:
      result = decode_negative(mrb, r, info);
      break;
    case 2:
      result = decode_bytes(mrb, r, src, info);
      break;
    case 3:
      result = decode_text(mrb, r, src, info);
      break;
    case 4:
      result = decode_array(mrb, r, src, info, sharedrefs, false);
      break;
    case 5:
      result = decode_map(mrb, r, src, info, sharedrefs, false);
      break;
    case 6: {
      /* tag is already an mrb_value — no conversion needed for hash lookup or
         ivar storage, and mrb_cmp handles all comparisons without C numerics */
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

      /* Check tag registry before falling back to UnhandledTag */
      {
        mrb_value reg   = cbor_tag_registry(mrb);
        mrb_value klass = mrb_hash_fetch(mrb, reg, tag, mrb_undef_value());
        if (mrb_class_p(klass)) {
          result = decode_registered_tag(mrb, r, src, sharedrefs, klass);
          goto done;
        }
      }

      /* Unknown tag: wrap in UnhandledTag */
      mrb_value tagged_value = decode_value(mrb, r, src, sharedrefs);
      struct RClass *unhandled_tag = mrb_class_get_under_id(mrb,
        mrb_module_get_id(mrb, MRB_SYM(CBOR)), MRB_SYM(UnhandledTag));
      result = mrb_obj_new(mrb, unhandled_tag, 0, NULL);
      mrb_iv_set(mrb, result, MRB_IVSYM(tag),   tag);   /* already mrb_value */
      mrb_iv_set(mrb, result, MRB_IVSYM(value), tagged_value);
      goto done;
    }

    case 7:
      if (info < 20) {
        result = mrb_nil_value();
        break;
      }
      switch (info) {
        case 20:
          result = mrb_false_value();
          break;
        case 21:
          result = mrb_true_value();
          break;
        case 22:
        case 23:
          result = mrb_nil_value();
          break;
        case 24:
          result = decode_null_with_skip(mrb, r, info);
          break;
#ifndef MRB_NO_FLOAT
        case 25:
        case 26:
        case 27:
          result = decode_float(mrb, r, info);
          break;
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
}

static size_t next_pow2(size_t x)
{
  x--;
  x |= x >> 1;
  x |= x >> 2;
  x |= x >> 4;
  x |= x >> 8;
  x |= x >> 16;
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
    size_t initial = stack_len + need;
    size_t capa = next_pow2(initial);

    w->heap_str = mrb_str_new_capa(mrb, (mrb_int)capa);
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
  size_t heap_len  = w->heap_len;
  size_t heap_capa = w->heap_capa;

  if (likely(add <= heap_capa - heap_len)) {
    return;
  }

  if (likely(add <= SIZE_MAX - heap_len)) {
    size_t need = heap_len + add;
    size_t capa = next_pow2(need);

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

    if (likely(mrb_undef_p(w->heap_str) &&
              len <= CBOR_SBO_STACK_CAP - stack_len)) {

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

  if (likely(mrb_undef_p(w->heap_str))) {
    return mrb_str_new(mrb,
                       (const char*)w->stack_buf,
                       (mrb_int)w->stack_len);
  } else if (likely(mrb_string_p(w->heap_str))) {
    struct RString *s = RSTRING(w->heap_str);
    RSTR_SET_LEN(s, (mrb_int)w->heap_len);
    w->heap_ptr[w->heap_len] = '\0';
    return w->heap_str;
  } else {
    mrb_raise(mrb, E_TYPE_ERROR,"heap string is not a string");
  }
  return mrb_undef_value();
}

static void
encode_len(CborWriter *w, uint8_t major, uint64_t v)
{
  uint8_t buf[1 + 8];
  size_t  nbytes;

  if (v < 24) {
    buf[0] = (uint8_t)((major << 5) | (uint8_t)v);
    nbytes = 1;
  } else if (v <= 0xFFu) {
    buf[0] = (uint8_t)((major << 5) | 24);
    buf[1] = (uint8_t)v;
    nbytes = 2;
  } else if (v <= 0xFFFFu) {
    buf[0] = (uint8_t)((major << 5) | 25);
    buf[1] = (uint8_t)(v >> 8);
    buf[2] = (uint8_t)(v);
    nbytes = 3;
  } else if (v <= 0xFFFFFFFFu) {
    buf[0] = (uint8_t)((major << 5) | 26);
    buf[1] = (uint8_t)(v >> 24);
    buf[2] = (uint8_t)(v >> 16);
    buf[3] = (uint8_t)(v >> 8);
    buf[4] = (uint8_t)(v);
    nbytes = 5;
  } else {
    buf[0] = (uint8_t)((major << 5) | 27);
    buf[1] = (uint8_t)(v >> 56);
    buf[2] = (uint8_t)(v >> 48);
    buf[3] = (uint8_t)(v >> 40);
    buf[4] = (uint8_t)(v >> 32);
    buf[5] = (uint8_t)(v >> 24);
    buf[6] = (uint8_t)(v >> 16);
    buf[7] = (uint8_t)(v >> 8);
    buf[8] = (uint8_t)(v);
    nbytes = 9;
  }

  cbor_writer_write(w, buf, nbytes);
}

static void
encode_integer(CborWriter *w, mrb_int n)
{
  if (n >= 0) {
    encode_len(w, 0, (uint64_t)n);
  } else {
    encode_len(w, 1, (uint64_t)(-1 - n));
  }
}

static void
encode_uint64(CborWriter *w, uint64_t v)
{
  encode_len(w, 0, v);
}

static void
encode_int64(CborWriter *w, int64_t n)
{
  if (n >= 0) {
    encode_len(w, 0, (uint64_t)n);
  } else {
    encode_len(w, 1, (uint64_t)(-1 - n));
  }
}

// ============================================================================
// Shared reference tracking
// ============================================================================

static mrb_bool
encode_check_shared(CborWriter *w, mrb_value obj)
{
  if (mrb_undef_p(w->seen)) return FALSE;
  mrb_state *mrb = w->mrb;

  mrb_value id_key = mrb_int_value(mrb, mrb_obj_id(obj));
  mrb_value found  = mrb_hash_get(mrb, w->seen, id_key);

  if (mrb_integer_p(found)) {
    uint8_t tag29[2] = { 0xD8, 0x1D };
    cbor_writer_write(w, tag29, 2);
    encode_len(w, 0, (uint64_t)mrb_integer(found));
    return TRUE;
  }

  mrb_hash_set(mrb, w->seen, id_key, mrb_int_value(mrb, mrb_hash_size(mrb, w->seen)));

  uint8_t tag28[2] = { 0xD8, 0x1C };
  cbor_writer_write(w, tag28, 2);
  return FALSE;
}

// ============================================================================
// BigInt encoding (Tag 2/3)
// ============================================================================
#ifdef MRB_USE_BIGINT
static void
encode_bignum(CborWriter *w, mrb_value obj)
{
  mrb_state *mrb = w->mrb;
  mrb_int idx = mrb_gc_arena_save(mrb);

  mrb_int sign = mrb_bint_sign(mrb, obj);

  if (mrb_bint_size(mrb, obj) <= 8) {
    if (sign >= 0) {
      encode_uint64(w, mrb_bint_as_uint64(mrb, obj));
      mrb_gc_arena_restore(mrb, idx);
      return;
    }
  }

  mrb_value mag = mrb_bint_abs(mrb, obj);

  if (sign < 0) {
    mrb_value one = mrb_fixnum_value(1);
    mag = mrb_bint_sub(mrb, mag, one);
  }

  mrb_value hex = mrb_bint_to_s(mrb, mag, 16);
  char *p = RSTRING_PTR(hex);
  mrb_int len = RSTRING_LEN(hex);

  while (len > 0 && *p == '0') { p++; len--; }

  if (len == 0) {
    uint8_t tag = (sign < 0) ? 0xC3 : 0xC2;
    cbor_writer_write(w, &tag, 1);
    encode_len(w, 2, 1);
    uint8_t zero = 0;
    cbor_writer_write(w, &zero, 1);
    mrb_gc_arena_restore(mrb, idx);
    return;
  }

  mrb_bool odd = (len & 1);
  mrb_int nibs = odd ? (len + 1) : len;
  mrb_int byte_len = nibs / 2;

  uint8_t tag = (sign < 0) ? 0xC3 : 0xC2;
  cbor_writer_write(w, &tag, 1);
  encode_len(w, 2, (uint64_t)byte_len);

  if (odd) {
    memmove(p + 1, p, len);
    p[0] = '0';
  }

  uint8_t *out = (uint8_t*)mrb_alloca(mrb, byte_len);
  hex_decode_scalar(out, p, byte_len);
  cbor_writer_write(w, out, (size_t)byte_len);
  mrb_gc_arena_restore(mrb, idx);
}
#endif

// ============================================================================
// Array / Map
// ============================================================================
static void encode_value(CborWriter* w, mrb_value obj);

static void
encode_array(CborWriter* w, mrb_value ary)
{
  unsigned int was_frozen = mrb_basic_ptr(ary)->frozen;
  mrb_basic_ptr(ary)->frozen = TRUE;
  struct RArray *a = mrb_ary_ptr(ary);

  mrb_int len = ARY_LEN(a);
  encode_len(w, 4, (uint64_t)len);

  mrb_value *ptr = ARY_PTR(a);

  for (mrb_int i = 0; i < len; i++) {
    encode_value(w, ptr[i]);
  }
  mrb_basic_ptr(ary)->frozen = was_frozen;
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
  unsigned int was_frozen = mrb_basic_ptr(hash)->frozen;
  mrb_basic_ptr(hash)->frozen = TRUE;
  struct RHash *h = mrb_hash_ptr(hash);

  mrb_int len = mrb_hash_size(mrb, hash);
  encode_len(w, 5, (uint64_t)len);

  mrb_hash_foreach(mrb, h, encode_map_foreach, w);
  mrb_basic_ptr(hash)->frozen = was_frozen;
}

// ============================================================================
// Text
// ============================================================================
static void
encode_string(CborWriter* w, mrb_value str)
{
  const char* p = RSTRING_PTR(str);
  mrb_int blen  = RSTRING_LEN(str);

  if (mrb_str_is_utf8(str)) {
    encode_len(w, 3, (uint64_t)blen);
  } else {
    encode_len(w, 2, (uint64_t)blen);
  }

  cbor_writer_write(w, (const uint8_t*)p, (size_t)blen);
}

// ============================================================================
// Simple
// ============================================================================
static void
encode_simple(CborWriter* w, mrb_value obj)
{
  uint8_t b;

  switch (mrb_type(obj)) {

    case MRB_TT_FALSE: {
      if (mrb_nil_p(obj)) {
        b = 0xF6;
      } else {
        b = 0xF4;
      }
    } break;

    case MRB_TT_TRUE:
      b = 0xF5;
      break;

    default: {
      mrb_state *mrb = w->mrb;
      mrb_raise(mrb, E_TYPE_ERROR, "unexpected simple value");
      b = 0;
    } break;
  }
  cbor_writer_write(w, &b, 1);
}

#ifndef MRB_NO_FLOAT
static void
encode_float(CborWriter *w, mrb_float f)
{
#ifdef MRB_USE_FLOAT32
  mrb_static_assert(sizeof(mrb_float) == sizeof(uint32_t));
  uint8_t buf[1 + 4];
  buf[0] = 0xFA;
  uint32_t u;
  memcpy(&u, &f, sizeof(uint32_t));
  buf[1] = (uint8_t)(u >> 24);
  buf[2] = (uint8_t)(u >> 16);
  buf[3] = (uint8_t)(u >> 8);
  buf[4] = (uint8_t)(u);
  cbor_writer_write(w, buf, 5);
#else
  mrb_static_assert(sizeof(mrb_float) == sizeof(uint64_t));
  uint8_t buf[1 + 8];
  buf[0] = 0xFB;
  uint64_t u;
  memcpy(&u, &f, sizeof(uint64_t));
  buf[1] = (uint8_t)(u >> 56);
  buf[2] = (uint8_t)(u >> 48);
  buf[3] = (uint8_t)(u >> 40);
  buf[4] = (uint8_t)(u >> 32);
  buf[5] = (uint8_t)(u >> 24);
  buf[6] = (uint8_t)(u >> 16);
  buf[7] = (uint8_t)(u >> 8);
  buf[8] = (uint8_t)(u);
  cbor_writer_write(w, buf, 9);
#endif
}
#endif

static void
encode_sym(CborWriter *w, mrb_value obj)
{
  mrb_state *mrb = w->mrb;
  mrb_value mode = cbor_sym_strategy(mrb);

  if (mrb_cmp(mrb, mode, mrb_fixnum_value(0)) == 0) {
    mrb_sym s = mrb_symbol(obj);
    mrb_value str = mrb_sym2str(mrb, s);
    encode_string(w, str);
    return;
  }

  if (mrb_cmp(mrb, mode, mrb_fixnum_value(1)) == 0) {
    mrb_sym s = mrb_symbol(obj);
    mrb_value str = mrb_sym2str(mrb, s);
    encode_len(w, 6, 39);
    encode_string(w, str);
    return;
  }

  if (mrb_cmp(mrb, mode, mrb_fixnum_value(2)) == 0) {
    mrb_sym s = mrb_symbol(obj);
    encode_len(w, 6, 39);
    encode_len(w, 0, s);
    return;
  }

  mrb_raise(mrb, E_RUNTIME_ERROR, "invalid symbol strategy mode");
}


static void
encode_value(CborWriter* w, mrb_value obj)
{
  mrb_state* mrb = w->mrb;
  if (!mrb_undef_p(w->seen)) {
      if (!mrb_immediate_p(obj) && encode_check_shared(w, obj)) {
          return;
      }
  }

  switch (mrb_type(obj)) {
    case MRB_TT_FALSE:
    case MRB_TT_TRUE:
      encode_simple(w, obj);
      break;

    case MRB_TT_SYMBOL:
      encode_sym(w, obj);
      break;

#ifndef MRB_NO_FLOAT
    case MRB_TT_FLOAT:
      encode_float(w, mrb_float(obj));
      break;
#endif

    case MRB_TT_INTEGER:
      encode_integer(w, mrb_integer(obj));
      break;

    case MRB_TT_STRING:
      encode_string(w, obj);
      break;

    case MRB_TT_ARRAY:
      encode_array(w, obj);
      break;

    case MRB_TT_HASH:
      encode_map(w, obj);
      break;

#ifdef MRB_USE_BIGINT
    case MRB_TT_BIGINT:
      encode_bignum(w, obj);
      break;
#endif

    default: {
      mrb_value rev     = cbor_tag_rev_registry(mrb);
      mrb_value klass   = mrb_obj_value(mrb_class(mrb, obj));
      mrb_value tag_val = mrb_hash_fetch(mrb, rev, klass, mrb_undef_value());
      if (mrb_integer_p(tag_val)) {
        encode_registered_tag(w, obj, mrb_integer(tag_val));
      } else {
        mrb_value s = mrb_obj_as_string(mrb, obj);
        encode_string(w, s);
      }
    } break;
  }
}


// ============================================================================
// Ruby bindings
// ============================================================================
static mrb_value
mrb_cbor_encode(mrb_state* mrb, mrb_value self)
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
  }

  encode_value(&w, obj);
  return cbor_writer_finish(&w);
}

static mrb_value
mrb_cbor_decode(mrb_state* mrb, mrb_value self)
{
  mrb_value src;
  Reader r;

  (void)self;

  mrb_get_args(mrb, "S", &src);
  src = mrb_str_byte_subseq(mrb, src, 0, RSTRING_LEN(src));

  reader_init(&r, (const uint8_t*)RSTRING_PTR(src), (size_t)RSTRING_LEN(src));

  return decode_value(mrb, &r, src, mrb_ary_new(mrb));
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
  mrb_iv_set(mrb, obj, MRB_SYM(sharedrefs),  sharedrefs);
  return obj;
}


/* ============================================================
 * Tag registry
 * ============================================================ */

static mrb_value
cbor_tag_registry(mrb_state *mrb)
{
  mrb_value cbor = mrb_obj_value(mrb_module_get_id(mrb, MRB_SYM(CBOR)));
  mrb_value reg  = mrb_iv_get(mrb, cbor, MRB_SYM(__cbor_tag_registry__));
  if (likely(mrb_hash_p(reg))) {
    return reg;
  } else {
    reg = mrb_hash_new(mrb);
    mrb_iv_set(mrb, cbor, MRB_SYM(__cbor_tag_registry__), reg);
    return reg;
  }
}

static mrb_value
cbor_tag_rev_registry(mrb_state *mrb)
{
  mrb_value cbor = mrb_obj_value(mrb_module_get_id(mrb, MRB_SYM(CBOR)));
  mrb_value reg  = mrb_iv_get(mrb, cbor, MRB_SYM(__cbor_tag_rev_registry__));
  if (likely(mrb_hash_p(reg))) {
    return reg;
  } else {
    reg = mrb_hash_new(mrb);
    mrb_iv_set(mrb, cbor, MRB_SYM(__cbor_tag_rev_registry__), reg);
    return reg;
  }
}

static mrb_value
mrb_cbor_register_tag(mrb_state *mrb, mrb_value self)
{
  mrb_value tag_v;
  mrb_value klass;
  mrb_get_args(mrb, "oC", &tag_v, &klass);

  if (!mrb_integer_p(tag_v))
    mrb_raise(mrb, E_TYPE_ERROR, "tag must be an integer");

  /* Reject tags reserved for internal use */
  static const int reserved[] = { 2, 3, 28, 29, 39 };
  for (uint8_t i = 0; i < sizeof(reserved) / sizeof(reserved[0]); i++) {
    if (unlikely(mrb_cmp(mrb, tag_v, mrb_fixnum_value(reserved[i])) == 0))
      mrb_raisef(mrb, E_ARGUMENT_ERROR,
        "tag %v is reserved for internal CBOR use", tag_v);
  }

  mrb_value fwd = cbor_tag_registry(mrb);
  mrb_value rev = cbor_tag_rev_registry(mrb);

  {
    struct RClass *kp_check = mrb_class_ptr(klass);
    if (unlikely(MRB_INSTANCE_TT(kp_check) != MRB_TT_OBJECT))
      mrb_raise(mrb, E_TYPE_ERROR, "registered tag class must be a plain Ruby class (not CDATA or other native type)");
    if (unlikely(kp_check == mrb->string_class  ||
        kp_check == mrb->array_class   ||
        kp_check == mrb->hash_class    ||
        kp_check == mrb->float_class   ||
        kp_check == mrb->integer_class ||
        kp_check == mrb->true_class    ||
        kp_check == mrb->false_class   ||
        kp_check == mrb->nil_class     ||
        kp_check == mrb->symbol_class  ||
        kp_check == mrb->eException_class))
      mrb_raise(mrb, E_TYPE_ERROR, "cannot register built-in class as CBOR tag");
  }

  /* tag_v is already mrb_value — use directly as hash key */
  mrb_hash_set(mrb, fwd, tag_v, klass);
  mrb_hash_set(mrb, rev, klass, tag_v);

  return mrb_nil_value();
}

static void encode_value(CborWriter *w, mrb_value obj); /* forward */

typedef struct {
  CborWriter *w;
  mrb_value   obj;
} TagEncodeCtx;

static int
encode_registered_tag_foreach(mrb_state *mrb, mrb_value sym, mrb_value mask, void *data)
{
  TagEncodeCtx *ctx = (TagEncodeCtx*)data;
  CborWriter *w = ctx->w;
  mrb_value obj = ctx->obj;

  mrb_int slen;
  const char *sname = mrb_sym_name_len(mrb, mrb_symbol(sym), &slen);
  while (slen > 0 && sname[0] == '@') { sname++; slen--; }

  encode_len(w, 3, (uint64_t)slen);
  cbor_writer_write(w, (const uint8_t*)sname, (size_t)slen);

  mrb_value val = mrb_iv_get(mrb, obj, mrb_symbol(sym));

  if (mrb_integer_p(mask)) {
    /* actual_major is an internal bitmask index, not a CBOR value — uint8_t is correct here */
    uint8_t actual_major = 6;

    switch (mrb_type(val)) {
      case MRB_TT_INTEGER: {
        mrb_int i = mrb_integer(val);
        actual_major = (i >= 0) ? 0 : 1;
        break;
      }
      case MRB_TT_STRING: {
        actual_major = mrb_str_is_utf8(val) ? 3 : 2;
        break;
      }
      case MRB_TT_ARRAY:
        actual_major = 4;
        break;
      case MRB_TT_HASH:
        actual_major = 5;
        break;
      case MRB_TT_FALSE:
      case MRB_TT_TRUE:
#ifndef MRB_NO_FLOAT
      case MRB_TT_FLOAT:
#endif
        actual_major = 7;
        break;
#ifdef MRB_USE_BIGINT
      case MRB_TT_BIGINT:
        if (mrb_bint_size(mrb, val) <= 8) {
          actual_major = (mrb_bint_sign(mrb, val) >= 0) ? 0 : 1;
        } else {
          actual_major = 6;
        }
        break;
#endif
      case MRB_TT_SYMBOL: {
        mrb_value mode = cbor_sym_strategy(mrb);
        if (mrb_cmp(mrb, mode, mrb_fixnum_value(2)) == 0) {
          actual_major = 6;
        } else {
          mrb_value str = mrb_sym2str(mrb, mrb_symbol(val));
          actual_major = mrb_str_is_utf8(str) ? 3 : 2;
        }
        break;
      }
      default:
        actual_major = 6;
    }

    mrb_int allowed = mrb_integer(mask);
    if (unlikely(!((allowed >> actual_major) & 1))) {
      mrb_raisef(mrb, E_TYPE_ERROR,
        "CBOR tag field type mismatch for ivar %v", sym);
    }
  }

  encode_value(w, val);
  return 0;
}

static void
encode_registered_tag(CborWriter *w, mrb_value obj, mrb_int tag_num)
{
  mrb_state *mrb = w->mrb;

  encode_len(w, 6, (uint64_t)tag_num);

  mrb_value schema = mrb_net_schema(mrb, mrb_class(mrb, obj));
  if (likely(mrb_hash_p(schema))) {
    mrb_int n = mrb_hash_size(mrb, schema);
    encode_len(w, 5, (uint64_t)n);

    TagEncodeCtx ctx = { w, obj };

    mrb_hash_foreach(mrb, mrb_hash_ptr(schema),
                    encode_registered_tag_foreach, &ctx);
  } else {
    mrb_raise(mrb, E_RUNTIME_ERROR, "registered class has no ned schema");
  }
}

typedef struct {
  mrb_value obj;
  mrb_value payload;
} decode_ctx;

static int
decode_registered_tag_foreach(mrb_state *mrb, mrb_value sym, mrb_value mask, void *data)
{
  decode_ctx *ctx = (decode_ctx*)data;

  mrb_int slen;
  const char *sname = mrb_sym_name_len(mrb, mrb_symbol(sym), &slen);
  while (slen > 0 && sname[0] == '@') { sname++; slen--; }

  mrb_value map_key = mrb_str_new_static(mrb, sname, slen);
  mrb_value val = mrb_hash_fetch(mrb, ctx->payload, map_key, mrb_undef_value());

  if (!mrb_undef_p(val) && mrb_integer_p(mask)) {
    uint8_t actual_major = 6;

    switch (mrb_type(val)) {
      case MRB_TT_INTEGER: {
        mrb_int i = mrb_integer(val);
        actual_major = (i >= 0) ? 0 : 1;
        break;
      }
      case MRB_TT_STRING: {
        actual_major = mrb_str_is_utf8(val) ? 3 : 2;
        break;
      }
      case MRB_TT_ARRAY:
        actual_major = 4;
        break;
      case MRB_TT_HASH:
        actual_major = 5;
        break;
      case MRB_TT_FALSE:
      case MRB_TT_TRUE:
#ifndef MRB_NO_FLOAT
      case MRB_TT_FLOAT:
#endif
        actual_major = 7;
        break;
#ifdef MRB_USE_BIGINT
      case MRB_TT_BIGINT:
        if (mrb_bint_size(mrb, val) <= 8) {
          actual_major = (mrb_bint_sign(mrb, val) >= 0) ? 0 : 1;
        } else {
          actual_major = 6;
        }
        break;
#endif
      case MRB_TT_SYMBOL: {
        mrb_value mode = cbor_sym_strategy(mrb);
        if (mrb_cmp(mrb, mode, mrb_fixnum_value(2)) == 0) {
          actual_major = 6;
        } else {
          mrb_value str = mrb_sym2str(mrb, mrb_symbol(val));
          actual_major = mrb_str_is_utf8(str) ? 3 : 2;
        }
        break;
      }
      default:
        actual_major = 6;
    }

    mrb_int allowed = mrb_integer(mask);
    if (unlikely(!((allowed >> actual_major) & 1))) {
      mrb_raisef(mrb, E_TYPE_ERROR,
        "CBOR tag field type mismatch for ivar %v", sym);
    }
  }

  mrb_iv_set(mrb, ctx->obj, mrb_symbol(sym),
             mrb_undef_p(val) ? mrb_nil_value() : val);

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

      mrb_hash_foreach(mrb, mrb_hash_ptr(schema),
                      decode_registered_tag_foreach, &ctx);

      if (mrb_respond_to(mrb, obj, MRB_SYM(from_allocate))) {
        return mrb_funcall_argv(mrb, obj, MRB_SYM(from_allocate), 0, NULL);
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

    case 0: /* unsigned integer */
    case 1: /* negative integer */
      if (info >= 24) read_cbor_uint(mrb, r, info); /* consume extra bytes */
      break;

    case 2: /* byte string */
    case 3: { /* text string */
      mrb_value len_v = read_cbor_uint(mrb, r, info);
      mrb_int len = cbor_value_to_len(mrb, len_v);
      reader_advance_checked(mrb, r, len);
      break;
    }

    case 4: { /* array */
      mrb_value len_v = read_cbor_uint(mrb, r, info);
      mrb_int len = cbor_value_to_len(mrb, len_v);
      for (mrb_int i = 0; i < len; i++)
        skip_cbor(mrb, r, buf, sharedrefs);
      break;
    }

    case 5: { /* map */
      mrb_value len_v = read_cbor_uint(mrb, r, info);
      mrb_int len = cbor_value_to_len(mrb, len_v);
      for (mrb_int i = 0; i < len; i++) {
        skip_cbor(mrb, r, buf, sharedrefs); /* key */
        skip_cbor(mrb, r, buf, sharedrefs); /* value */
      }
      break;
    }

    case 6: {
      mrb_value tag = read_cbor_uint(mrb, r, info);

      if (mrb_cmp(mrb, tag, mrb_fixnum_value(28)) == 0) {
        if (likely(mrb_array_p(sharedrefs))) {
          mrb_int inner_offset = cbor_pdiff(mrb, r->p, r->base);
          mrb_value lazy = cbor_lazy_new(mrb, buf, inner_offset, sharedrefs);
          mrb_ary_push(mrb, sharedrefs, lazy);
        } else {
          mrb_raise(mrb, E_TYPE_ERROR, "sharedrefs is not a array");
        }
      }
      /* tag 29: just skip the uint index, nothing to register */

      skip_cbor(mrb, r, buf, sharedrefs);
      break;
    }

    case 7: {
      if (info < 24) break;
      switch (info) {
        case 24: if (likely(r->p < r->end)) { r->p++; break; }
                 mrb_raise(mrb, E_RANGE_ERROR, "simple value out of bounds");
        case 25: if (likely((r->end - r->p) >= 2)) { r->p += 2; break; }
                 mrb_raise(mrb, E_RANGE_ERROR, "float16 out of bounds");
        case 26: if (likely((r->end - r->p) >= 4)) { r->p += 4; break; }
                 mrb_raise(mrb, E_RANGE_ERROR, "float32 out of bounds");
        case 27: if (likely((r->end - r->p) >= 8)) { r->p += 8; break; }
                 mrb_raise(mrb, E_RANGE_ERROR, "float64 out of bounds");
        case 31: mrb_raise(mrb, E_NOTIMP_ERROR, "indefinite-length items not supported");
      }
      break;
    }

    default:
      mrb_raisef(mrb, E_NOTIMP_ERROR, "Not implemented CBOR major type '%d'", major);
  }

  r->depth--;
}

/* Lazy#value */
MRB_API mrb_value
cbor_lazy_value(mrb_state *mrb, mrb_value self)
{
  mrb_value vcache = mrb_iv_get(mrb, self, MRB_SYM(vcache));
  if (!mrb_undef_p(vcache)) return vcache;

  cbor_lazy_t *p = mrb_data_get_ptr(mrb, self, &cbor_lazy_type);

  const uint8_t *base = (const uint8_t*)RSTRING_PTR(p->buf);
  size_t total_len    = (size_t)RSTRING_LEN(p->buf);
  mrb_value sharedrefs = mrb_iv_get(mrb, self, MRB_SYM(sharedrefs));

  if (likely((size_t)p->offset < total_len)) {
    Reader r;
    r.base = base;
    r.p    = base + p->offset;
    r.end  = base + total_len;
    r.depth = 0;

    mrb_value value = decode_value(mrb, &r, p->buf, sharedrefs);
    if (mrb_data_check_get_ptr(mrb, value, &cbor_lazy_type)) value = cbor_lazy_value(mrb, value);
    mrb_iv_set(mrb, self, MRB_SYM(vcache), value);
    return value;
  } else {
    mrb_raise(mrb, E_RANGE_ERROR, "lazy offset out of bounds");
  }

  return mrb_undef_value();
}

/* ============================================================
 * Lazy CBOR access
 * ============================================================ */

static mrb_value
lazy_fetch_from_cache(mrb_state *mrb, mrb_value self, mrb_value key)
{
  mrb_value kcache = mrb_iv_get(mrb, self, MRB_SYM(kcache));
  if (likely(mrb_hash_p(kcache))) {
    return mrb_hash_fetch(mrb, kcache, key, mrb_undef_value());
  }
  mrb_raise(mrb, E_TYPE_ERROR, "kcache is not a hash");
}

static void
lazy_reader_init(mrb_state *mrb, Reader *r, cbor_lazy_t *p)
{
  const uint8_t *base = (const uint8_t*)RSTRING_PTR(p->buf);
  size_t total_len    = (size_t)RSTRING_LEN(p->buf);

  if (likely((size_t)p->offset < total_len)) {
    r->base = base;
    r->p    = base + p->offset;
    r->end  = base + total_len;
    r->depth = 0;
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
    mrb_value normalized_key = mrb_ensure_int_type(mrb, key);
    mrb_int idx = mrb_integer(normalized_key);

    mrb_value len_v = read_cbor_uint(mrb, r, r->info);
    mrb_int len = cbor_value_to_len(mrb, len_v);

    if (idx < 0) idx += len;
    if (unlikely(idx >= len || idx < 0)) {
      mrb_raisef(mrb, E_INDEX_ERROR,
        "index %d outside of array bounds: -%d...%d",
        idx, len, len);
    }

    for (mrb_int i = 0; i < idx; i++) {
      skip_cbor(mrb, r, p->buf, sharedrefs);
    }

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
    mrb_value pairs_v = read_cbor_uint(mrb, r, r->info);
    mrb_int pairs = cbor_value_to_len(mrb, pairs_v);
    mrb_bool key_is_str = mrb_string_p(key);

    for (mrb_int i = 0; i < pairs; i++) {
      mrb_bool match;

      uint8_t kb    = reader_read8(mrb, r);
      uint8_t kmaj  = (uint8_t)(kb >> 5);
      uint8_t kinfo = (uint8_t)(kb & 0x1F);

      if (key_is_str && (kmaj == 2 || kmaj == 3)) {
        mrb_value klen_v = read_cbor_uint(mrb, r, kinfo);
        mrb_int klen = cbor_value_to_len(mrb, klen_v);
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
    mrb_raise(mrb, E_TYPE_ERROR, "kcache is not a hash");
  }

  return mrb_undef_value();
}

/*
 * Advance reader past any wrapping tags (major=6) until we reach a
 * non-tag item.  Handles Tag 28 and Tag 29 for shared references.
 * Returns resolved major type, or 0xFF if Tag 29 was encountered
 * (in which case *resolved_out is set to the referenced Lazy).
 */
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
    /* Tag 28 or any other tag: just consume and read next header */
    reader_read_header(mrb, r);
  }
  return r->major;
}

static mrb_value
cbor_lazy_aref(mrb_state *mrb, mrb_value self, mrb_value key)
{
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
      case 4:
        return lazy_aref_array(mrb, &r, key, self, p, sharedrefs);
      case 5:
        return lazy_aref_map(mrb, &r, key, self, p, sharedrefs);
      case 0xFF: {
        if (mrb_data_check_get_ptr(mrb, resolved, &cbor_lazy_type)) {
          return cbor_lazy_aref(mrb, resolved, key);
        }
      }
      default:
        mrb_raise(mrb, E_TYPE_ERROR, "not indexable");
    }
  } else {
    mrb_raise(mrb, E_TYPE_ERROR, "sharedrefs is not a array");
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
mrb_cbor_decode_lazy(mrb_state *mrb, mrb_value self)
{
  mrb_value buf;
  mrb_get_args(mrb, "S", &buf);

  mrb_value owned_buf = mrb_str_byte_subseq(mrb, buf, 0, RSTRING_LEN(buf));
  mrb_value sharedrefs = mrb_ary_new(mrb);

  return cbor_lazy_new(mrb, owned_buf, 0, sharedrefs);
}

static mrb_value
cbor_lazy_dig(mrb_state *mrb, mrb_value self)
{
  mrb_value *keys;
  mrb_int    nkeys;
  mrb_get_args(mrb, "*", &keys, &nkeys);

  if (nkeys == 0) return self;

  /* Limit dig nesting to prevent pathological recursion */
  if (unlikely(nkeys > CBOR_MAX_DEPTH / 2)) {
    mrb_raise(mrb, E_RUNTIME_ERROR, "CBOR#dig nesting too deep");
  }

  mrb_value current = self;

  for (mrb_int ki = 0; ki < nkeys; ki++) {
    if (mrb_nil_p(current)) return mrb_nil_value();

    cbor_lazy_t *p = mrb_data_get_ptr(mrb, current, &cbor_lazy_type);
    mrb_value key  = keys[ki];

    mrb_value kcache = mrb_iv_get(mrb, current, MRB_SYM(kcache));
    if (likely(mrb_hash_p(kcache))) {
      mrb_value cached = mrb_hash_fetch(mrb, kcache, key, mrb_undef_value());
      if (!mrb_undef_p(cached)) {
        current = cached;
        continue;
      }
    } else {
      mrb_raise(mrb, E_RUNTIME_ERROR, "kcache is not a hash");
    }

    const uint8_t *base    = (const uint8_t *)RSTRING_PTR(p->buf);
    size_t         total   = (size_t)RSTRING_LEN(p->buf);
    mrb_value      sharedrefs = mrb_iv_get(mrb, current, MRB_SYM(sharedrefs));

    if (unlikely((size_t)p->offset >= total))
      mrb_raise(mrb, E_RUNTIME_ERROR, "lazy offset out of bounds");

    Reader r;
    r.base = base;
    r.p    = base + p->offset;
    r.end  = base + total;
    r.depth = 0;

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
        mrb_value nkey = mrb_ensure_int_type(mrb, key);
        mrb_int   idx  = mrb_integer(nkey);
        mrb_value len_v = read_cbor_uint(mrb, &r, r.info);
        mrb_int   len  = cbor_value_to_len(mrb, len_v);

        if (idx < 0) idx += len;
        if (idx < 0 || idx >= len) { current = mrb_nil_value(); continue; }

        for (mrb_int i = 0; i < idx; i++)
          skip_cbor(mrb, &r, current, sharedrefs);

        mrb_int  elem_off = cbor_pdiff(mrb, r.p, base);
        result = cbor_lazy_new(mrb, p->buf, elem_off, sharedrefs);
        mrb_hash_set(mrb, kcache, key, result);

      } break;

      case 5: {
        mrb_value pairs_v  = read_cbor_uint(mrb, &r, r.info);
        mrb_int   pairs    = cbor_value_to_len(mrb, pairs_v);
        mrb_bool  key_is_str = mrb_string_p(key);
        mrb_bool  found      = FALSE;

        for (mrb_int i = 0; i < pairs; i++) {
          mrb_bool match;

          uint8_t kb    = reader_read8(mrb, &r);
          uint8_t kmaj  = kb >> 5;
          uint8_t kinfo = kb & 0x1F;

          if (key_is_str && (kmaj == 2 || kmaj == 3)) {
            mrb_value klen_v = read_cbor_uint(mrb, &r, kinfo);
            mrb_int klen = cbor_value_to_len(mrb, klen_v);
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

static mrb_value
cbor_no_symbols(mrb_state *mrb, mrb_value self)
{
  cbor_set_sym_strategy(mrb, 0);
  return self;
}

static mrb_value
cbor_symbols_as_string(mrb_state *mrb, mrb_value self)
{
  cbor_set_sym_strategy(mrb, 1);
  return self;
}

static mrb_value
cbor_symbols_as_uint32(mrb_state *mrb, mrb_value self)
{
#ifdef MRB_NO_PRESYM
  mrb_raise(mrb, E_NOTIMP_ERROR, "mruby was compiled without presym, symbols_as_uint32 is not available.");
#else
  cbor_set_sym_strategy(mrb, 2);
#endif
  return self;
}

MRB_BEGIN_DECL

MRB_API void
mrb_mruby_cbor_gem_init(mrb_state* mrb)
{
  struct RClass* cbor = mrb_define_module_id(mrb, MRB_SYM(CBOR));
  mrb_define_module_function_id(mrb, cbor, MRB_SYM(no_symbols), cbor_no_symbols, MRB_ARGS_NONE());
  mrb_define_module_function_id(mrb, cbor, MRB_SYM(symbols_as_uint32), cbor_symbols_as_uint32, MRB_ARGS_NONE());
  mrb_define_module_function_id(mrb, cbor, MRB_SYM(symbols_as_string), cbor_symbols_as_string, MRB_ARGS_NONE());
  mrb_define_module_function_id(mrb, cbor, MRB_SYM(decode), mrb_cbor_decode, MRB_ARGS_REQ(1));
  mrb_define_module_function_id(mrb, cbor, MRB_SYM(register_tag), mrb_cbor_register_tag, MRB_ARGS_REQ(2));
  mrb_define_module_function_id(mrb, cbor, MRB_SYM(encode), mrb_cbor_encode, MRB_ARGS_REQ(1)|MRB_ARGS_KEY(0, 1));

  struct RClass *lazy = mrb_define_class_under_id(mrb, cbor, MRB_SYM(Lazy), mrb->object_class);
  MRB_SET_INSTANCE_TT(lazy, MRB_TT_CDATA);

  mrb_define_method_id(mrb, lazy, MRB_OPSYM(aref),  cbor_lazy_aref_m,  MRB_ARGS_REQ(1));
  mrb_define_method_id(mrb, lazy, MRB_SYM(value),   cbor_lazy_value, MRB_ARGS_NONE());
  mrb_define_method_id(mrb, lazy, MRB_SYM(dig),     cbor_lazy_dig,   MRB_ARGS_ANY());

  mrb_define_module_function_id(mrb, cbor, MRB_SYM(decode_lazy),
                                mrb_cbor_decode_lazy, MRB_ARGS_REQ(1));

  struct RClass *type_mod = mrb_define_module_under_id(mrb, cbor, MRB_SYM(Type));
  mrb_define_const_id(mrb, type_mod, MRB_SYM(UnsignedInt),  mrb_fixnum_value(1 << 0));
  mrb_define_const_id(mrb, type_mod, MRB_SYM(NegativeInt),  mrb_fixnum_value(1 << 1));
  mrb_define_const_id(mrb, type_mod, MRB_SYM(Bytes),        mrb_fixnum_value(1 << 2));
  mrb_define_const_id(mrb, type_mod, MRB_SYM(String),       mrb_fixnum_value(1 << 3));
  mrb_define_const_id(mrb, type_mod, MRB_SYM(Array),        mrb_fixnum_value(1 << 4));
  mrb_define_const_id(mrb, type_mod, MRB_SYM(Map),          mrb_fixnum_value(1 << 5));
  mrb_define_const_id(mrb, type_mod, MRB_SYM(Tagged),       mrb_fixnum_value(1 << 6));
  mrb_define_const_id(mrb, type_mod, MRB_SYM(Simple),       mrb_fixnum_value(1 << 7));
  mrb_define_const_id(mrb, type_mod, MRB_SYM(Integer),      mrb_fixnum_value((1 << 0) | (1 << 1)));
  mrb_define_const_id(mrb, type_mod, MRB_SYM(BytesOrString), mrb_fixnum_value((1 << 2) | (1 << 3)));
}


MRB_API void
mrb_mruby_cbor_gem_final(mrb_state* mrb)
{
  (void)mrb;
}

MRB_END_DECL