#include <mruby.h>
#include <mruby/string.h>
#include <mruby/array.h>
#include <mruby/hash.h>
#include <mruby/class.h>
#include <stdlib.h>
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

#include <stdint.h>
#include <stddef.h>
#include <string.h>
#include <stdbool.h>

#ifndef _WIN32
# include <sys/types.h>
# include <sys/stat.h>
# include <sys/mman.h>
# include <fcntl.h>
# include <unistd.h>
#else
# include <windows.h>
#endif
/* ============================================================
 * scalar fallback
 * ============================================================ */

static inline uint8_t hex_nibble(uint8_t c)
{
    /* '0'-'9': bit6 = 0  ->  (c & 0xF) + 0
       'a'-'f': bit6 = 1  ->  (c & 0xF) + 9
       'A'-'F': bit6 = 1  ->  (c & 0xF) + 9   */
    return (uint8_t)((c & 0xF) + ((c >> 6) & 1) * 9);
}

static void
hex_decode_scalar(uint8_t * restrict out, const char * restrict in, size_t n)
{
    /* n = Anzahl Output-Bytes (= len/2) */
    for (size_t i = 0; i < n; i++) {
        out[i] = (uint8_t)(
            (hex_nibble((uint8_t)in[2*i    ]) << 4) |
             hex_nibble((uint8_t)in[2*i + 1])
        );
    }
}

// ============================================================================
// Reader
// ============================================================================

typedef struct {
  const uint8_t* base;
  const uint8_t* p;
  const uint8_t* end;

  uint8_t major;
  uint8_t info;
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
}

static size_t
reader_offset(const Reader* r)
{
  return (size_t)(r->p - r->base);
}

typedef struct {
  uint64_t v;
  uint8_t size;
} Num;

static Num
read_num(mrb_state* mrb, Reader* r, uint8_t info)
{
  Num out;
  out.v    = 0;
  out.size = 0;

  const uint8_t* p   = r->p;
  const uint8_t* end = r->end;

  if (info < 24) {
    out.v = info;
    out.size = 1;
    return out;
  }

  switch (info) {
    case 24:
      if (likely(end - p >= 1)) {
        out.v    = p[0];
        out.size = 1;
        r->p     = p + 1;
        return out;
      }
      mrb_raise(mrb, E_RANGE_ERROR, "invalid uint8");
      return out;

    case 25:
      if (likely(end - p >= 2)) {
        out.v    = ((uint16_t)p[0] << 8) | p[1];
        out.size = 2;
        r->p     = p + 2;
        return out;
      }
      mrb_raise(mrb, E_RANGE_ERROR, "invalid uint16");
      return out;

    case 26:
      if (likely(end - p >= 4)) {
        out.v =
          ((uint32_t)p[0] << 24) |
          ((uint32_t)p[1] << 16) |
          ((uint32_t)p[2] << 8)  |
          ((uint32_t)p[3]);
        out.size = 4;
        r->p     = p + 4;
        return out;
      }
      mrb_raise(mrb, E_RANGE_ERROR, "invalid uint32");
      return out;

    case 27:
      if (likely(end - p >= 8)) {
        out.v =
          ((uint64_t)p[0] << 56) |
          ((uint64_t)p[1] << 48) |
          ((uint64_t)p[2] << 40) |
          ((uint64_t)p[3] << 32) |
          ((uint64_t)p[4] << 24) |
          ((uint64_t)p[5] << 16) |
          ((uint64_t)p[6] << 8)  |
          ((uint64_t)p[7]);
        out.size = 8;
        r->p     = p + 8;
        return out;
      }
      mrb_raise(mrb, E_RANGE_ERROR, "invalid uint64");
      return out;
    case 31: mrb_raise(mrb, E_NOTIMP_ERROR, "indefinite-length items not supported");
  }

  mrb_raisef(mrb, E_RUNTIME_ERROR, "invalid integer encoding: %d", info);
  return out;
}

static mrb_value
decode_unsigned(mrb_state* mrb, Reader* r, uint8_t info)
{
  Num n = read_num(mrb, r, info);

  switch (n.size) {
    case 1: return mrb_convert_uint8(mrb, n.v);
    case 2: return mrb_convert_uint16(mrb, n.v);
    case 4: return mrb_convert_uint32(mrb, n.v);
    case 8: return mrb_convert_uint64(mrb, n.v);
  }

  mrb_raise(mrb, E_RANGE_ERROR, "invalid integer size");
  return mrb_nil_value();
}

static mrb_value
decode_negative(mrb_state* mrb, Reader* r, uint8_t info)
{
  Num n = read_num(mrb, r, info);

  switch (n.size) {
    case 1: return mrb_convert_int8(mrb,  (int8_t)(-1 - (uint8_t)n.v));
    case 2: return mrb_convert_int16(mrb, (int16_t)(-1 - (uint16_t)n.v));
    case 4: return mrb_convert_int32(mrb, (int32_t)(-1 - (uint32_t)n.v));
    case 8: return mrb_convert_int64(mrb, (int64_t)(-1 - (uint64_t)n.v));
  }

  mrb_raise(mrb, E_RANGE_ERROR, "invalid integer size");
  return mrb_undef_value();
}

// ============================================================================
// Length / bounds helpers
// ============================================================================
static uint64_t
read_len(mrb_state* mrb, Reader* r, uint8_t info)
{
  if (info < 24) return info;
  Num n = read_num(mrb, r, info);
  return n.v;
}

static void
ensure_slice_bounds(mrb_state* mrb, mrb_value src, size_t off, uint64_t len)
{
  size_t slen = (size_t)RSTRING_LEN(src);

  /* Fast path: alles im gueltigen Bereich, ohne Overflow-Risiko */
  if (likely(off <= slen && len <= slen - off)) {
    return;
  }

  /* Slow path: irgendwas ist out of bounds */
  mrb_raise(mrb, E_RANGE_ERROR, "slice out of bounds");
}

// ============================================================================
// Bytes / Text
// ============================================================================
static mrb_value
decode_text(mrb_state* mrb, Reader* r, mrb_value src, uint8_t info)
{
  uint64_t blen = read_len(mrb, r, info);
  size_t off    = reader_offset(r);

  if (likely(blen <= SIZE_MAX - off && off + blen <= (size_t)RSTRING_LEN(src))) {
      mrb_value slice = mrb_str_byte_subseq(mrb, src, (mrb_int)off, (mrb_int)blen);

#ifdef MRB_UTF8_STRING
      if (likely(mrb_str_is_utf8(slice))) {
        r->p += blen;
        return slice;
      } else {
        mrb_raise(mrb, E_RUNTIME_ERROR, "string slice isn't utf8");
      }
#else
      r->p += blen;
      return slice;
#endif
  } else {
      mrb_raise(mrb, E_RANGE_ERROR, "text string out of bounds");
      return mrb_undef_value();
  }
}

static mrb_value
decode_bytes(mrb_state* mrb, Reader* r, mrb_value src, uint8_t info)
{
  uint64_t blen = read_len(mrb, r, info);
  size_t off    = reader_offset(r);

  if (likely(blen <= SIZE_MAX - off && off + blen <= (size_t)RSTRING_LEN(src))) {
      r->p += blen;
      return mrb_str_byte_subseq(mrb, src, (mrb_int)off, (mrb_int)blen);;
  } else {
      mrb_raise(mrb, E_RANGE_ERROR, "byte string out of bounds");
  }

  return mrb_undef_value();
}

static mrb_value decode_value(mrb_state* mrb, Reader* r, mrb_value src, mrb_value shareable);

static mrb_value
decode_array(mrb_state* mrb, Reader* r, mrb_value src, uint8_t info, mrb_value shareable, mrb_int share_idx)
{
  uint64_t len = read_len(mrb, r, info);
  mrb_value ary = mrb_ary_new(mrb);
  mrb_int idx = mrb_gc_arena_save(mrb);

  if (share_idx >= 0)
    mrb_hash_set(mrb, shareable, mrb_int_value(mrb, share_idx), ary);


  for (uint64_t i = 0; i < len; i++) {
    mrb_value v = decode_value(mrb, r, src, shareable);
    mrb_ary_push(mrb, ary, v);
    mrb_gc_arena_restore(mrb, idx);
  }

  return ary;
}

static mrb_value
decode_map(mrb_state* mrb, Reader* r, mrb_value src, uint8_t info, mrb_value shareable, mrb_int share_idx)
{
  uint64_t len = read_len(mrb, r, info);
  mrb_value hash = mrb_hash_new(mrb);
  mrb_int idx = mrb_gc_arena_save(mrb);

  if (share_idx >= 0)
    mrb_hash_set(mrb, shareable, mrb_int_value(mrb, share_idx), hash);


  for (uint64_t i = 0; i < len; i++) {
    mrb_value key = decode_value(mrb, r, src, shareable);
    mrb_value val = decode_value(mrb, r, src, shareable);
    mrb_hash_set(mrb, hash, key, val);
    mrb_gc_arena_restore(mrb, idx);
  }

  return hash;
}

// ============================================================================
// Simple / Float
// ============================================================================
#ifndef MRB_NO_FLOAT
static mrb_value
decode_simple_or_float(mrb_state* mrb, Reader* r, uint8_t info)
{
  if (info < 20) return mrb_nil_value();

  switch (info) {
    case 20: return mrb_false_value();
    case 21: return mrb_true_value();
    case 22:
    case 23: return mrb_nil_value();
    case 24: {
      reader_read8(mrb, r);
      return mrb_nil_value();
    }

    /* ---------------------- Float16 ---------------------- */
    case 25: {
      uint16_t h =
        ((uint16_t)reader_read8(mrb, r) << 8) |
        ((uint16_t)reader_read8(mrb, r));

      uint16_t sign = h & 0x8000u;
      uint16_t exp  = h & 0x7C00u;
      uint16_t frac = h & 0x03FFu;

      uint32_t f;

      if (exp == 0x7C00u) {
        /* Inf or NaN: exponent all-ones in float32 = 0xFF */
        f = ((uint32_t)sign << 16) | 0x7F800000u | ((uint32_t)frac << 13);
      } else if (exp != 0) {
        /* Normal number */
        uint32_t new_exp  = (uint32_t)((exp >> 10) + (127 - 15)) << 23;
        uint32_t new_frac = (uint32_t)frac << 13;
        f = ((uint32_t)sign << 16) | new_exp | new_frac;
      } else if (frac == 0) {
        /* Zero */
        f = (uint32_t)sign << 16;
      } else {
        /* Subnormal: normalize */
        uint32_t mant = frac;
        int shift = 0;
        while ((mant & 0x0400u) == 0) {
          mant <<= 1;
          shift++;
        }
        mant &= 0x03FFu;
        uint32_t new_exp  = (uint32_t)(127 - 14 - shift) << 23;
        uint32_t new_frac = mant << 13;
        f = ((uint32_t)sign << 16) | new_exp | new_frac;
      }

      float f32;
      memcpy(&f32, &f, sizeof(float));
      return mrb_float_value(mrb, (mrb_float)f32);
    }

    /* ---------------------- Float32 ---------------------- */
    case 26: {
      uint32_t u =
        ((uint32_t)reader_read8(mrb, r) << 24) |
        ((uint32_t)reader_read8(mrb, r) << 16) |
        ((uint32_t)reader_read8(mrb, r) << 8)  |
        ((uint32_t)reader_read8(mrb, r));

      float f32;
      memcpy(&f32, &u, sizeof(float));
      return mrb_float_value(mrb, (mrb_float)f32);
    }

    /* ---------------------- Float64 ---------------------- */
    case 27: {
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
      return mrb_float_value(mrb, (mrb_float)f64);
    }

    case 31: mrb_raise(mrb, E_NOTIMP_ERROR, "indefinite-length items not supported");
  }

  mrb_raise(mrb, E_RUNTIME_ERROR, "invalid simple/float");
  return mrb_undef_value();
}

#else
static mrb_value
decode_simple_or_float(mrb_state* mrb, Reader* r, uint8_t info)
{
  if (info < 20) return mrb_nil_value();

  switch (info) {
    case 20:
      return mrb_false_value();

    case 21:
      return mrb_true_value();

    case 22:
    case 23: return mrb_nil_value();
    case 24: {
      reader_read8(mrb, r);
      return mrb_nil_value();
    }
    case 31: mrb_raise(mrb, E_NOTIMP_ERROR, "indefinite-length items not supported");
  }

  mrb_raise(mrb, E_NOTIMP_ERROR, "can't unpack floats or doubles since its disabled for this mruby runtime");
}
#endif

#ifdef MRB_USE_BIGINT
static mrb_value
decode_tagged_bignum(mrb_state* mrb, Reader* r, mrb_value src, uint64_t tag)
{
  mrb_int idx = mrb_gc_arena_save(mrb);

  /* Read inner header */
  uint8_t b2 = reader_read8(mrb, r);
  uint8_t major2 = (uint8_t)(b2 >> 5);
  uint8_t info2  = (uint8_t)(b2 & 0x1F);

  if (unlikely(major2 != 2))
    mrb_raise(mrb, E_RUNTIME_ERROR, "invalid bignum payload");

  uint64_t len = read_len(mrb, r, info2);
  if (len == 0)
    mrb_raise(mrb, E_RUNTIME_ERROR, "invalid bignum: zero length");

  size_t off = reader_offset(r);
  ensure_slice_bounds(mrb, src, off, len);
  r->p += len;

  const uint8_t* buf = (const uint8_t*)RSTRING_PTR(src) + off;
  mrb_bool negative = (tag == 3);

  const uint8_t* bigbuf = buf;   /* pointer we will actually use */

#ifndef MRB_ENDIAN_BIG
  /* Only reverse if len > 1 */
  if (len > 1) {
    uint8_t *tmp = mrb_alloca(mrb, len);
    memcpy(tmp, buf, len);

    /* Reverse for little-endian MRuby */
    for (size_t i = 0, j = len - 1; i < j; i++, j--) {
      uint8_t t = tmp[i];
      tmp[i] = tmp[j];
      tmp[j] = t;
    }
    bigbuf = tmp;
  }
#endif

  /* Convert bytes -> positive BigInt */
  mrb_value n = mrb_bint_from_bytes(mrb, bigbuf, (mrb_int)len);
  mrb_gc_arena_restore(mrb, idx);
  mrb_gc_protect(mrb, n);

  if (!negative)
    return n;

  /* Tag 3: -(n+1) */

  if (mrb_integer_p(n)) {
    mrb_int v = mrb_integer(n);
    mrb_int result = -1 - v;
    mrb_value ret = mrb_int_value(mrb, result);
    mrb_gc_arena_restore(mrb, idx);
    mrb_gc_protect(mrb, ret);
    return ret;
  }

  mrb_value one = mrb_fixnum_value(1);
  mrb_value n_plus_1 = mrb_bint_add(mrb, n, one);
  mrb_value ret = mrb_bint_neg(mrb, n_plus_1);

  mrb_gc_arena_restore(mrb, idx);
  mrb_gc_protect(mrb, ret);
  return ret;
}
#endif

static mrb_value
decode_tag_shareable(mrb_state* mrb, Reader* r,
                     mrb_value src, mrb_value shareable)
{
  if (likely(mrb_hash_p(shareable))) {
    mrb_int share_idx = mrb_hash_size(mrb, shareable);
    mrb_value idx_key = mrb_int_value(mrb, share_idx);

    uint8_t nb     = reader_read8(mrb, r);
    uint8_t major2 = nb >> 5;
    uint8_t info2  = nb & 0x1F;

    switch (major2) {
      case 4: /* array */
        return decode_array(mrb, r, src, info2, shareable, share_idx);
      case 5: /* map */
        return decode_map(mrb, r, src, info2, shareable, share_idx);
      default:
        break;
    }

    /* scalar shareable: register placeholder first */
    mrb_hash_set(mrb, shareable, idx_key, mrb_undef_value());

    mrb_value inner;
    switch (major2) {
      case 0: inner = decode_unsigned(mrb, r, info2); break;
      case 1: inner = decode_negative(mrb, r, info2); break;
      case 2: inner = decode_bytes(mrb, r, src, info2); break;
      case 3: inner = decode_text(mrb, r, src, info2); break;
      case 6:
        read_len(mrb, r, info2);
        inner = decode_value(mrb, r, src, shareable);
        break;
      case 7:
        inner = decode_simple_or_float(mrb, r, info2);
        break;
      default:
        mrb_raisef(mrb, E_NOTIMP_ERROR, "Not implemented major type '%d' in shareable", major2);
        inner = mrb_undef_value(); /* not reached */
    }

    mrb_hash_set(mrb, shareable, idx_key, inner);
    return inner;
  } else {
    mrb_raise(mrb, E_TYPE_ERROR, "shareable is not a hash");
  }
}

static mrb_value
decode_tag_sharedref(mrb_state* mrb, Reader* r, mrb_value shareable)
{
  if (likely(mrb_hash_p(shareable))) {
    uint8_t ref_b     = reader_read8(mrb, r);
    uint8_t ref_major = ref_b >> 5;
    uint8_t ref_info  = ref_b & 0x1F;

    if (likely(ref_major == 0)) {
      mrb_value key   = mrb_convert_uint64(mrb, read_len(mrb, r, ref_info));
      mrb_value found = mrb_hash_fetch(mrb, shareable, key, mrb_undef_value());

      if (likely(!mrb_undef_p(found))) {
        return found;
      } else {
        mrb_raisef(mrb, E_INDEX_ERROR, "sharedref index %v not found", key);
      }
    } else {
      mrb_raise(mrb, E_TYPE_ERROR, "sharedref payload must be unsigned integer");
    }
  } else {
    mrb_raise(mrb, E_TYPE_ERROR, "shareable is not a hash");
  }

  return mrb_undef_value(); /* not reached */
}

// ============================================================================
// Master decode
// ============================================================================
static mrb_value
decode_value(mrb_state* mrb, Reader* r, mrb_value src, mrb_value shareable)
{
  uint8_t b = reader_read8(mrb, r);
  uint8_t major = (uint8_t)(b >> 5);
  uint8_t info = (uint8_t)(b & 0x1F);

  switch (major) {
    case 0: return decode_unsigned(mrb, r, info);
    case 1: return decode_negative(mrb, r, info);
    case 2: return decode_bytes(mrb, r, src, info);
    case 3: return decode_text(mrb, r, src, info);
    case 4: return decode_array(mrb, r, src, info, shareable, -1);
    case 5: return decode_map(mrb, r, src, info, shareable, -1);
    case 6: {
      uint64_t tag = read_len(mrb, r, info);

      switch (tag) {
        case 2:
        case 3: {
#ifdef MRB_USE_BIGINT
          return decode_tagged_bignum(mrb, r, src, tag);
#else
          goto unknown_tag;
#endif

        } break;

        case 28: return decode_tag_shareable(mrb, r, src, shareable);
        case 29: return decode_tag_sharedref(mrb, r, shareable);

      }
#ifndef MRB_USE_BIGINT
unknown_tag:;
#endif

      mrb_value tagged_value = decode_value(mrb, r, src, shareable);
      struct RClass *unhandled_tag = mrb_class_get_under_id(mrb, mrb_module_get_id(mrb, MRB_SYM(CBOR)), MRB_SYM(UnhandledTag));
      mrb_value result = mrb_obj_new(mrb, unhandled_tag, 0, NULL);
      mrb_iv_set(mrb, result, MRB_IVSYM(tag), mrb_convert_uint64(mrb, tag));
      mrb_iv_set(mrb, result, MRB_IVSYM(value), tagged_value);
      return result;
    }

    case 7: return decode_simple_or_float(mrb, r, info);
  }

  mrb_raisef(mrb, E_NOTIMP_ERROR, "Not implemented major type %d", major);
  return mrb_undef_value();
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
  mrb_int   seen_start; /* first index assigned to the first shareable object */
} CborWriter;

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

  w->seen       = mrb_hash_new(mrb);
  w->seen_start = 0;
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

  /* Fast path: Addition ohne Overflow moeglich */
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

  /* Slow path: Overflow -> Fehler */
  mrb_raise(mrb, E_RANGE_ERROR, "heap size overflow");
}

static void
cbor_writer_ensure_heap(CborWriter *w, size_t add)
{
  size_t heap_len  = w->heap_len;
  size_t heap_capa = w->heap_capa;

  /* Fast path: genug Platz, keine Arbeit */
  if (likely(add <= heap_capa - heap_len)) {
    return;
  }

  /* Jetzt muessen wir wachsen; Overflow dabei verhindern, aber wieder mit positivem likely-Guard */
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

    /* Fast path: nur Stack, kein Overflow */
    if (likely(mrb_undef_p(w->heap_str) &&
              len <= CBOR_SBO_STACK_CAP - stack_len)) {

      memcpy(w->stack_buf + stack_len, buf, len);
      w->stack_len = stack_len + len;

    } else {
      /* Slow path: entweder Heap noetig oder Overflow im Stack-Pfad */

      /* Heap initialisieren, falls noch nicht geschehen */
      if (mrb_undef_p(w->heap_str)) {
        /* positiver Overflow-Guard */
        if (likely(len <= SIZE_MAX - stack_len)) {
          cbor_writer_init_heap(w, len);
        } else {
          mrb_state *mrb = w->mrb;
          mrb_raise(mrb, E_RANGE_ERROR, "heap size overflow");
        }
      }

      /* Heap erweitern */
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

  if (mrb_undef_p(w->heap_str)) {
    /* alles im Stack geblieben */
    return mrb_str_new(mrb,
                       (const char*)w->stack_buf,
                       (mrb_int)w->stack_len);
  }

  struct RString *s = RSTRING(w->heap_str);
  RSTR_SET_LEN(s, (mrb_int)w->heap_len);
  w->heap_ptr[w->heap_len] = '\0';

  return w->heap_str;
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

/*
 * Returns TRUE  -> Tag 29 (sharedref) emitted, caller must NOT encode obj.
 * Returns FALSE -> Tag 28 (shareable) emitted, caller MUST encode obj normally.
 * When w->seen is undef (sharedrefs disabled) this is a no-op returning FALSE.
 */
static mrb_bool
encode_check_shared(CborWriter *w, mrb_value obj)
{
  if (mrb_undef_p(w->seen)) return FALSE;

  mrb_state *mrb = w->mrb;
  mrb_value found = mrb_hash_fetch(mrb, w->seen, mrb_int_value(mrb, mrb_obj_id(obj)), mrb_undef_value());

  if (mrb_integer_p(found)) {
    /* Already seen: emit Tag 29 + absolute index */
    uint8_t tag29[2] = { 0xD8, 0x1D };
    cbor_writer_write(w, tag29, 2);
    encode_len(w, 0, (uint64_t)mrb_integer(found));
    return TRUE;
  }

  /* First time: compute absolute index, register, emit Tag 28 */
  mrb_int idx = w->seen_start + mrb_hash_size(mrb, w->seen);
  mrb_hash_set(mrb, w->seen, mrb_int_value(mrb, mrb_obj_id(obj)), mrb_int_value(mrb, idx));

  uint8_t tag28[2] = { 0xD8, 0x1C };
  cbor_writer_write(w, tag28, 2);
  return FALSE;
}

// ============================================================================
// BigInt encoding (Tag 2/3) - mrb_bint_to_s ist native endian -> korrigieren
// ============================================================================
#ifdef MRB_USE_BIGINT
static void
encode_bignum(CborWriter *w, mrb_value obj)
{
  mrb_state *mrb = w->mrb;
  mrb_int idx = mrb_gc_arena_save(mrb);

  mrb_int sign = mrb_bint_sign(mrb, obj);

  /* Fast path: fits in 64 bits -> encode as normal integer, no tag/hex needed */
  if (mrb_bint_size(mrb, obj) <= 8) {
    if (sign >= 0) {
      encode_uint64(w, mrb_bint_as_uint64(mrb, obj));
    } else {
      encode_int64(w, mrb_bint_as_int64(mrb, obj));
    }
    mrb_gc_arena_restore(mrb, idx);
    return;
  }

  /* Slow path: truly large bigint -> Tag 2/3 + hex encode */

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
  struct RArray *a = mrb_ary_ptr(ary);

  mrb_int len = ARY_LEN(a);
  encode_len(w, 4, (uint64_t)len);

  mrb_value *ptr = ARY_PTR(a);

  for (mrb_int i = 0; i < len; i++) {
    encode_value(w, ptr[i]);
  }
}

static int
encode_map_foreach(mrb_state *mrb, mrb_value key, mrb_value val, void *data)
{
  CborWriter *w = (CborWriter*)data;

  encode_value(w, key);
  encode_value(w, val);

  return 0; /* continue */
}

static void
encode_map(CborWriter* w, mrb_value hash)
{
  mrb_state *mrb = w->mrb;
  struct RHash *h = mrb_hash_ptr(hash);

  /* Anzahl der Paare */
  mrb_int len = mrb_hash_size(mrb, hash);
  encode_len(w, 5, (uint64_t)len);

  /* direkte Iteration ueber Hash-Table */
  mrb_hash_foreach(mrb, h, encode_map_foreach, w);
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
    /* UTF-8 -> CBOR Text (Major 3) */
    encode_len(w, 3, (uint64_t)blen);
  } else {
    /* Nicht UTF-8 -> CBOR Bytes (Major 2) */
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
        b = 0xF6;   /* null */
      } else {
        b = 0xF4;   /* false */
      }
    } break;

    case MRB_TT_TRUE:
      b = 0xF5;     /* true */
      break;

    default: {
      mrb_state *mrb = w->mrb;
      mrb_raise(mrb, E_TYPE_ERROR, "unexpected simple value");
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
encode_value(CborWriter* w, mrb_value obj)
{
  mrb_state* mrb = w->mrb;

  switch (mrb_type(obj)) {
    case MRB_TT_FALSE:
    case MRB_TT_TRUE:
      encode_simple(w, obj);
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
      if (!encode_check_shared(w, obj)) encode_string(w, obj);
      break;

    case MRB_TT_ARRAY:
      if (!encode_check_shared(w, obj)) encode_array(w, obj);
      break;

    case MRB_TT_HASH:
      if (!encode_check_shared(w, obj)) encode_map(w, obj);
      break;

#ifdef MRB_USE_BIGINT
    case MRB_TT_BIGINT:
      encode_bignum(w, obj);
      break;
#endif

    default: {
      mrb_value s = mrb_obj_as_string(mrb, obj);
      if (!encode_check_shared(w, s)) encode_string(w, s);
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
  mrb_value  kw_values[1];
  kwargs.num      = 1;
  kwargs.required = 0;
  kwargs.table    = kw_keys;
  kwargs.values   = kw_values;
  kwargs.rest     = NULL;

  mrb_get_args(mrb, "o:", &obj, &kwargs);

  CborWriter w;
  cbor_writer_init(&w, mrb);


  if (!mrb_undef_p(kw_values[0]) && mrb_bool(kw_values[0])) {
    /* sharedrefs: true  -> indices start at 0
       sharedrefs: n     -> indices start at n */
    if (mrb_integer_p(kw_values[0])) {
      w.seen_start = mrb_integer(kw_values[0]);
    }
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

  return decode_value(mrb, &r, src, mrb_hash_new(mrb));
}

// ============================================================================
// CBOR::Lazy
// ============================================================================

typedef struct {
  mrb_value buf;    /* kompletter CBOR-String */
  uint32_t  offset; /* Start dieses Elements im buf (Byte-Index relativ zu base) */
} cbor_lazy_t;

static const struct mrb_data_type cbor_lazy_type = {
  "CBOR::Lazy", mrb_free
};

static mrb_value
cbor_lazy_new(mrb_state *mrb, mrb_value buf, uint32_t offset, mrb_value shareable)
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
  mrb_iv_set(mrb, obj, MRB_SYM(shareable),  shareable);
  return obj;
}

static void
skip_cbor(mrb_state *mrb, Reader *r, mrb_value buf, mrb_value shareable)
{
  if (unlikely(r->p >= r->end))
    mrb_raise(mrb, E_RUNTIME_ERROR, "unexpected end of buffer");

  uint8_t b     = reader_read8(mrb, r);
  uint8_t major = b >> 5;
  uint8_t info  = b & 0x1F;

  switch (major) {

    case 0: /* unsigned integer */
    case 1: /* negative integer */
      if (info >= 24) read_num(mrb, r, info);
      return;

    case 2: /* byte string */
    case 3: { /* text string */
      uint64_t len = read_len(mrb, r, info);
      if (likely((uint64_t)(r->end - r->p) >= len)) { r->p += len; return; }
      mrb_raise(mrb, E_RANGE_ERROR, "CBOR string out of bounds");
    }

    case 4: { /* array */
      uint64_t len = read_len(mrb, r, info);
      for (uint64_t i = 0; i < len; i++)
        skip_cbor(mrb, r, buf, shareable);
      return;
    }

    case 5: { /* map */
      uint64_t len = read_len(mrb, r, info);
      for (uint64_t i = 0; i < len; i++) {
        skip_cbor(mrb, r, buf, shareable); /* key */
        skip_cbor(mrb, r, buf, shareable); /* value */
      }
      return;
    }

    case 6: {
      uint64_t tag = read_len(mrb, r, info);

        if (tag == 28) {
          if (likely(mrb_hash_p(shareable))) {

            /* inner item offset - register as Lazy before skipping */
            mrb_int share_idx = mrb_hash_size(mrb, shareable);
            uint32_t inner_offset = (uint32_t)(r->p - r->base);
            mrb_value lazy = cbor_lazy_new(mrb, buf, inner_offset, shareable);
            mrb_hash_set(mrb, shareable, mrb_int_value(mrb, share_idx), lazy);
          } else {
            mrb_raise(mrb, E_TYPE_ERROR, "shareable is not a hash");
          }
        }
        skip_cbor(mrb, r, buf, shareable);
        /* tag 29: just skip the uint index, nothing to register */


      return;
    }

    case 7: {
      if (info < 24) return;
      switch (info) {
        case 24: if (likely(r->p < r->end)) { r->p++; return; }
                 mrb_raise(mrb, E_RANGE_ERROR, "simple value out of bounds");
        case 25: if (likely((r->end - r->p) >= 2)) { r->p += 2; return; }
                 mrb_raise(mrb, E_RANGE_ERROR, "float16 out of bounds");
        case 26: if (likely((r->end - r->p) >= 4)) { r->p += 4; return; }
                 mrb_raise(mrb, E_RANGE_ERROR, "float32 out of bounds");
        case 27: if (likely((r->end - r->p) >= 8)) { r->p += 8; return; }
                 mrb_raise(mrb, E_RANGE_ERROR, "float64 out of bounds");
        case 31: mrb_raise(mrb, E_NOTIMP_ERROR, "indefinite-length items not supported");
      }
    }
  }

  mrb_raisef(mrb, E_NOTIMP_ERROR, "Not implemented CBOR major type '%d'", major);
}

/* Lazy#value: vollstaendiges Dekodieren ab Element-Header (p->offset muss auf Header zeigen) */
MRB_API mrb_value
cbor_lazy_value(mrb_state *mrb, mrb_value self)
{
  mrb_value vcache = mrb_iv_get(mrb, self, MRB_SYM(vcache));
  if (!mrb_undef_p(vcache)) return vcache;

  cbor_lazy_t *p = DATA_PTR(self);

  const uint8_t *base = (const uint8_t*)RSTRING_PTR(p->buf);
  size_t total_len    = (size_t)RSTRING_LEN(p->buf);

  if (likely(p->offset < total_len)) {
    Reader r;
    r.base = base;
    r.p    = base + p->offset;
    r.end  = base + total_len;

    mrb_value value = decode_value(mrb, &r, p->buf, mrb_iv_get(mrb, self, MRB_SYM(shareable)));
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

/* kcache holen + fetch */
static mrb_value
lazy_fetch_from_cache(mrb_state *mrb, mrb_value self, mrb_value key)
{
  mrb_value kcache = mrb_iv_get(mrb, self, MRB_SYM(kcache));
  if (likely(mrb_hash_p(kcache))) {
    return mrb_hash_fetch(mrb, kcache, key, mrb_undef_value());
  }
  mrb_raise(mrb, E_TYPE_ERROR, "kcache is not a hash");
}

/* Reader für Lazy-Objekt initialisieren */
static void
lazy_reader_init(mrb_state *mrb, Reader *r, cbor_lazy_t *p)
{
  const uint8_t *base = (const uint8_t*)RSTRING_PTR(p->buf);
  size_t total_len    = (size_t)RSTRING_LEN(p->buf);

  if (likely(p->offset < total_len)) {
    r->base = base;
    r->p    = base + p->offset;
    r->end  = base + total_len;
  } else {
    mrb_raise(mrb, E_RANGE_ERROR, "lazy offset out of bounds");
  }
}

/* Array-Zugriff */
static mrb_value
lazy_aref_array(mrb_state *mrb, Reader *r, mrb_value key,
                mrb_value self, cbor_lazy_t *p, mrb_value shareable)
{
  mrb_value kcache = mrb_iv_get(mrb, self, MRB_SYM(kcache));
  if (likely(mrb_hash_p(kcache))) {
    mrb_value normalized_key = mrb_ensure_int_type(mrb, key);
    mrb_int idx = mrb_integer(normalized_key);

    uint64_t len = read_len(mrb, r, r->info);

    if (idx < 0) idx += (mrb_int)len;
    if (unlikely((uint64_t)idx >= len || idx < 0)) {
      mrb_raisef(mrb, E_INDEX_ERROR,
        "index %d outside of array bounds: -%d...%d",
        idx, (mrb_int)len, (mrb_int)len);
    }

    for (mrb_int i = 0; i < idx; i++) {
      skip_cbor(mrb, r, p->buf, shareable);
    }

    uint32_t elem_offset = (uint32_t)(r->p - r->base);
    mrb_value new_lazy = cbor_lazy_new(mrb, p->buf, elem_offset, shareable);

    mrb_hash_set(mrb, kcache, key, new_lazy);
    return new_lazy;
  } else {
    mrb_raise(mrb, E_TYPE_ERROR, "shareable is not a hash");
  }

  return mrb_undef_value(); /* unreachable */
}

/* Map-Zugriff */
static mrb_value
lazy_aref_map(mrb_state *mrb, Reader *r, mrb_value key,
              mrb_value self, cbor_lazy_t *p, mrb_value shareable)
{
  mrb_value kcache = mrb_iv_get(mrb, self, MRB_SYM(kcache));
  if (likely(mrb_hash_p(kcache))) {
    uint64_t pairs = read_len(mrb, r, r->info);
    mrb_bool key_is_str = mrb_string_p(key);

    for (uint64_t i = 0; i < pairs; i++) {
      mrb_bool match;

      uint8_t kb    = reader_read8(mrb, r);
      uint8_t kmaj  = (uint8_t)(kb >> 5);
      uint8_t kinfo = (uint8_t)(kb & 0x1F);

      if (key_is_str && (kmaj == 2 || kmaj == 3)) {
        uint64_t klen = read_len(mrb, r, kinfo);
        match = (klen == (uint64_t)RSTRING_LEN(key) &&
                (uint64_t)(r->end - r->p) >= klen &&
                memcmp(r->p, RSTRING_PTR(key), klen) == 0);
        r->p += klen;
      } else {
        r->p--;
        match = mrb_equal(mrb, decode_value(mrb, r, p->buf, shareable), key);
      }

      if (match) {
        uint32_t value_offset = (uint32_t)(r->p - r->base);
        mrb_value lazy_new = cbor_lazy_new(mrb, p->buf, value_offset, shareable);
        mrb_hash_set(mrb, kcache, key, lazy_new);
        return lazy_new;
      }

      skip_cbor(mrb, r, p->buf, shareable);
    }

    mrb_raisef(mrb, E_KEY_ERROR, "key not found: \"%v\"", key);
  } else {
    mrb_raise(mrb, E_TYPE_ERROR, "kcache is not a hash");
  }

  return mrb_undef_value(); /* unreachable */
}

static uint8_t
lazy_resolve_tags(mrb_state *mrb, Reader *r, mrb_value buf, mrb_value shareable)
{
  while (r->major == 6) {
    uint64_t tag = read_len(mrb, r, r->info);

    switch (tag) {
      case 29: {
        /* sharedref → eager auflösen */
        (void)decode_tag_sharedref(mrb, r, shareable);
        return 0xFF; /* Lazy kann hier nicht weiter */
      }

      case 28: {
        /* shareable → Index registrieren */
        mrb_int share_idx = mrb_hash_size(mrb, shareable);
        mrb_hash_set(mrb, shareable, mrb_int_value(mrb, share_idx), mrb_undef_value());

        /* nächsten Header lesen */
        reader_read_header(mrb, r);

        /* weiter in der Schleife, falls wieder Tag */
        continue;
      }

      default:
        /* generischer Tag → Lazy kann nicht korrekt arbeiten */
        return 0xFF;
    }
  }

  return r->major;
}



/* Lazy#[] */
static mrb_value
cbor_lazy_aref(mrb_state *mrb, mrb_value self)
{
  cbor_lazy_t *p = DATA_PTR(self);
  mrb_value key;
  mrb_get_args(mrb, "o", &key);

  mrb_value cached = lazy_fetch_from_cache(mrb, self, key);
  if (!mrb_undef_p(cached)) return cached;

  Reader r;
  lazy_reader_init(mrb, &r, p);
  reader_read_header(mrb, &r);

  mrb_value shareable = mrb_iv_get(mrb, self, MRB_SYM(shareable));
  if (likely(mrb_hash_p(shareable))) {
    uint8_t major = lazy_resolve_tags(mrb, &r, p->buf, shareable);
    switch (major) {
      case 4:
        return lazy_aref_array(mrb, &r, key, self, p, shareable);
      case 5:
        return lazy_aref_map(mrb, &r, key, self, p, shareable);
      default:
        mrb_raise(mrb, E_TYPE_ERROR, "not indexable");
    }
  } else {
    mrb_raise(mrb, E_TYPE_ERROR, "shareable is not a hash");
  }

  return mrb_undef_value();
}


static mrb_value
mrb_cbor_decode_lazy(mrb_state *mrb, mrb_value self)
{
  mrb_value buf;
  mrb_get_args(mrb, "S", &buf);

  mrb_value shareable = mrb_hash_new(mrb);

  return cbor_lazy_new(mrb,
                       mrb_str_byte_subseq(mrb, buf, 0, RSTRING_LEN(buf)),
                       0,
                       shareable);
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
    /* nil in the middle -> nil out */
    if (mrb_nil_p(current)) return mrb_nil_value();

    cbor_lazy_t *p = DATA_PTR(current);
    mrb_value key  = keys[ki];

    /* --- check kcache first --- */
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
    mrb_value      shareable = mrb_iv_get(mrb, current, MRB_SYM(shareable));

    if (unlikely(p->offset >= total))
      mrb_raise(mrb, E_RUNTIME_ERROR, "lazy offset out of bounds");

    Reader r;
    r.base = base;
    r.p    = base + p->offset;
    r.end  = base + total;

    reader_read_header(mrb, &r);
    uint8_t major = lazy_resolve_tags(mrb, &r, p->buf, shareable);

    mrb_value result;

    switch (major) {
      case 4: { /* Array */
        mrb_value nkey = mrb_ensure_int_type(mrb, key);
        mrb_int   idx  = mrb_integer(nkey);
        uint64_t  len  = read_len(mrb, &r, r.info);

        if (idx < 0) idx += (mrb_int)len;
        if (idx < 0 || (uint64_t)idx >= len) { current = mrb_nil_value(); continue; }

        for (mrb_int i = 0; i < idx; i++)
          skip_cbor(mrb, &r, p->buf, shareable);

        uint32_t  elem_off = (uint32_t)(r.p - base);
        result = cbor_lazy_new(mrb, p->buf, elem_off, shareable);
        mrb_hash_set(mrb, kcache, key, result);

      }break;

      case 5: { /* Map */
        uint64_t pairs     = read_len(mrb, &r, r.info);
        mrb_bool key_is_str = mrb_string_p(key);
        mrb_bool found      = FALSE;

        for (uint64_t i = 0; i < pairs; i++) {
          mrb_bool match;

          uint8_t kb    = reader_read8(mrb, &r);
          uint8_t kmaj  = kb >> 5;
          uint8_t kinfo = kb & 0x1F;

          if (key_is_str && (kmaj == 2 || kmaj == 3)) {
            uint64_t klen = read_len(mrb, &r, kinfo);
            match = (klen == (uint64_t)RSTRING_LEN(key) &&
                     (uint64_t)(r.end - r.p) >= klen &&
                     memcmp(r.p, RSTRING_PTR(key), klen) == 0);
            r.p += klen;
          } else {
            r.p--;
            match = mrb_equal(mrb, decode_value(mrb, &r, p->buf, shareable), key);
          }

          if (match) {
            uint32_t val_off = (uint32_t)(r.p - base);
            result = cbor_lazy_new(mrb, p->buf, val_off, shareable);
            mrb_hash_set(mrb, kcache, key, result);
            found = TRUE;
            break;
          }

          skip_cbor(mrb, &r, p->buf, shareable);
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


/* ============================================================
 * CborMappedFile struct + Finalizer
 * ============================================================ */

typedef struct {
  mrb_value path;
  const uint8_t *data;
  size_t size;

#ifndef _WIN32
  int fd;
#else
  HANDLE hFile;
  HANDLE hMap;
#endif
} CborMappedFile;

static void
cbor_mappedfile_free(mrb_state *mrb, void *ptr)
{
  CborMappedFile *m = (CborMappedFile*)ptr;
  if (!m) return;

#ifndef _WIN32
  if (m->data) munmap((void*)m->data, m->size);
  if (m->fd >= 0) close(m->fd);
#else
  if (m->data) UnmapViewOfFile(m->data);
  if (m->hMap) CloseHandle(m->hMap);
  if (m->hFile) CloseHandle(m->hFile);
#endif

  mrb_free(mrb, m);
}

static const struct mrb_data_type cbor_mappedfile_type = {
  "CborMappedFile", cbor_mappedfile_free
};


/* ============================================================
 * mmap / CreateFileMapping
 * ============================================================ */

#ifndef _WIN32
static void
cbor_map_file(mrb_state *mrb, CborMappedFile *m, mrb_value path)
{
  memset(m, 0, sizeof(*m));

  int fd = open(RSTRING_CSTR(mrb, path), O_RDONLY);
  if (fd < 0) mrb_sys_fail(mrb, "open");

  struct stat st;
  if (fstat(fd, &st) < 0) {
    close(fd);
    mrb_sys_fail(mrb, "fstat");
  }

  void *ptr = mmap(NULL, st.st_size, PROT_READ, MAP_PRIVATE, fd, 0);
  if (ptr == MAP_FAILED) {
    close(fd);
    mrb_sys_fail(mrb, "mmap");
  }

  m->path = path;
  m->data = (const uint8_t*)ptr;
  m->size = (size_t)st.st_size;
  m->fd   = fd;
}

#else

static void
cbor_map_file(mrb_state *mrb, CborMappedFile *m, mrb_value path)
{
  memset(m, 0, sizeof(*m));

  HANDLE hFile = CreateFileA(RSTRING_CSTR(mrb, path), GENERIC_READ, FILE_SHARE_READ,
                             NULL, OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, NULL);
  if (hFile == INVALID_HANDLE_VALUE) mrb_sys_fail(mrb, "CreateFileA");

  LARGE_INTEGER size;
  if (!GetFileSizeEx(hFile, &size)) {
    CloseHandle(hFile);
    mrb_sys_fail(mrb, "GetFileSizeEx");
  }

  HANDLE hMap = CreateFileMappingA(hFile, NULL, PAGE_READONLY, 0, 0, NULL);
  if (!hMap) {
    CloseHandle(hFile);
    mrb_sys_fail(mrb, "CreateFileMappingA");
  }

  void *ptr = MapViewOfFile(hMap, FILE_MAP_READ, 0, 0, 0);
  if (!ptr) {
    CloseHandle(hMap);
    CloseHandle(hFile);
    mrb_sys_fail(mrb, "MapViewOfFile");
  }

  m->path = path;
  m->data = (const uint8_t*)ptr;
  m->size = (size_t)size.QuadPart;
  m->hFile = hFile;
  m->hMap  = hMap;
}

#endif

static size_t
cbor_skip_document(mrb_state *mrb,
                   const uint8_t *data, size_t size, size_t offset,
                   mrb_value buf, mrb_value shareable)
{
  if (offset >= size) return offset;

  Reader r;
  reader_init(&r, data + offset, size - offset);

  /* skip genau EIN Top-Level-Item */
  skip_cbor(mrb, &r, buf, shareable);

  /* neuer Offset relativ zur Basis */
  return offset + reader_offset(&r);
}


static mrb_value
mrb_cbor_lazy_stream(mrb_state *mrb, mrb_value self)
{
  mrb_value path, block;
  mrb_get_args(mrb, "S&", &path, &block);
  path = mrb_str_byte_subseq(mrb, path, 0, RSTRING_LEN(path));

  if (!mrb_block_given_p(mrb)) {
    mrb_raise(mrb, E_ARGUMENT_ERROR, "block required");
  }

  /* CBOR::MappedFile holen */
  struct RClass *mappedfile =
      mrb_class_get_under_id(mrb, mrb_class_ptr(self), MRB_SYM(MappedFile));

  /* Mapping-Objekt erzeugen */
  CborMappedFile *m;
  struct RData *data;
  Data_Make_Struct(mrb, mappedfile, CborMappedFile,
                   &cbor_mappedfile_type, m, data);

  cbor_map_file(mrb, m, path);
  mrb_value mapped_file = mrb_obj_value(data);
  mrb_iv_set(mrb, mapped_file, MRB_SYM(path), path);

  /* zero-copy String auf mmap */
  mrb_value buf = mrb_str_new_static(
      mrb,
      (const char*)m->data,
      (mrb_int)m->size
  );

  /* shareable-Hash für Tag 28/29 - einmal pro Stream */
  mrb_value shareable = mrb_hash_new(mrb);

  size_t offset = 0;

  while (offset < m->size) {
    /* Lazy-Objekt für aktuelles Top-Level-Item */
    mrb_value lazy = cbor_lazy_new(mrb, buf, (mrb_int)offset, shareable);

    /* Mapping an Lazy hängen, damit mmap-Lifetime gesichert ist */
    mrb_iv_set(mrb, lazy, MRB_SYM(mapped_file), mapped_file);

    /* Block aufrufen */
    mrb_yield(mrb, block, lazy);

    /* nächstes Dokument finden */
    size_t next = cbor_skip_document(mrb, m->data, m->size, offset, buf, shareable);
    if (next <= offset) {
      mrb_raise(mrb, E_RUNTIME_ERROR, "invalid CBOR document boundary");
    }
    offset = next;
  }

  return mrb_nil_value();
}


MRB_BEGIN_DECL

MRB_API void
mrb_mruby_cbor_gem_init(mrb_state* mrb)
{
  struct RClass* cbor = mrb_define_module_id(mrb, MRB_SYM(CBOR));

  mrb_define_module_function_id(mrb, cbor, MRB_SYM(decode), mrb_cbor_decode, MRB_ARGS_REQ(1));
  mrb_define_module_function_id(mrb, cbor, MRB_SYM(encode), mrb_cbor_encode, MRB_ARGS_REQ(1)|MRB_ARGS_KEY(0, 1));

  struct RClass *lazy = mrb_define_class_under_id(mrb, cbor, MRB_SYM(Lazy), mrb->object_class);
  MRB_SET_INSTANCE_TT(lazy, MRB_TT_CDATA);

  mrb_define_method_id(mrb, lazy, MRB_OPSYM(aref),  cbor_lazy_aref,  MRB_ARGS_REQ(1));
  mrb_define_method_id(mrb, lazy, MRB_SYM(value),   cbor_lazy_value, MRB_ARGS_NONE());
  mrb_define_method_id(mrb, lazy, MRB_SYM(dig),     cbor_lazy_dig,   MRB_ARGS_ANY());

  struct RClass *mappedfile =
      mrb_define_class_under_id(mrb, cbor, MRB_SYM(MappedFile), mrb->object_class);
  MRB_SET_INSTANCE_TT(mappedfile, MRB_TT_CDATA);

  mrb_define_module_function_id(mrb, cbor, MRB_SYM(decode_lazy),
                                mrb_cbor_decode_lazy, MRB_ARGS_REQ(1));
  mrb_define_module_function_id(mrb, cbor, MRB_SYM(stream),
                                mrb_cbor_lazy_stream, MRB_ARGS_REQ(1)|MRB_ARGS_BLOCK());
}


MRB_API void
mrb_mruby_cbor_gem_final(mrb_state* mrb)
{
  (void)mrb;
}

MRB_END_DECL