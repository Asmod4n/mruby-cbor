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

#include <stdint.h>
#include <stddef.h>
#include <string.h>

// ============================================================================
// Reader
// ============================================================================

typedef struct {
  const uint8_t* base;
  const uint8_t* p;
  const uint8_t* end;
} Reader;

static void
reader_init(Reader* r, const uint8_t* buf, size_t len)
{
  r->base = buf;
  r->p    = buf;
  r->end  = buf + len;
}

static uint8_t
reader_read8(mrb_state* mrb, Reader* r)
{
  if (likely(r->p < r->end)) return *r->p++;
  mrb_raise(mrb, E_RUNTIME_ERROR, "unexpected end of buffer");
  return 0;
}

static mrb_bool
reader_eof(const Reader* r)
{
  return (r->p >= r->end);
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
      mrb_raise(mrb, E_RUNTIME_ERROR, "invalid uint8");
      return out;

    case 25:
      if (likely(end - p >= 2)) {
        out.v    = ((uint16_t)p[0] << 8) | p[1];
        out.size = 2;
        r->p     = p + 2;
        return out;
      }
      mrb_raise(mrb, E_RUNTIME_ERROR, "invalid uint16");
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
      mrb_raise(mrb, E_RUNTIME_ERROR, "invalid uint32");
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
      mrb_raise(mrb, E_RUNTIME_ERROR, "invalid uint64");
      return out;
  }

  mrb_raise(mrb, E_RUNTIME_ERROR, "invalid integer encoding");
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

  mrb_raise(mrb, E_RUNTIME_ERROR, "invalid integer size");
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

  mrb_raise(mrb, E_RUNTIME_ERROR, "invalid integer size");
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
  if (likely(off + len <= (size_t)RSTRING_LEN(src))) return;
  mrb_raise(mrb, E_RUNTIME_ERROR, "slice out of bounds");
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
      if (unlikely(!mrb_str_is_utf8(slice))) {
        mrb_raise(mrb, E_RUNTIME_ERROR, "string slice isn't utf8");
      }
#endif

      r->p += blen;
      return slice;
  } else {
      // alles andere ist wirklich out-of-bounds oder würde overflowen
      mrb_raise(mrb, E_RUNTIME_ERROR, "text string out of bounds");
  }

  return mrb_nil_value();
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
      // alles andere ist wirklich out-of-bounds oder würde overflowen
      mrb_raise(mrb, E_RUNTIME_ERROR, "text string out of bounds");
  }

  return mrb_nil_value();
}

static mrb_value
decode_value(mrb_state* mrb, Reader* r, mrb_value src);

static mrb_value
decode_array(mrb_state* mrb, Reader* r, mrb_value src, uint8_t info)
{
  uint64_t len = read_len(mrb, r, info);
  mrb_value ary = mrb_ary_new_capa(mrb, (mrb_int)len);
  mrb_int idx = mrb_gc_arena_save(mrb);

  for (uint64_t i = 0; i < len; i++) {
    mrb_value v = decode_value(mrb, r, src);
    mrb_ary_push(mrb, ary, v);
    mrb_gc_arena_restore(mrb, idx);
  }

  return ary;
}

static mrb_value
decode_map(mrb_state* mrb, Reader* r, mrb_value src, uint8_t info)
{
  uint64_t len = read_len(mrb, r, info);
  mrb_value hash = mrb_hash_new_capa(mrb, (mrb_int)len);
  mrb_int idx = mrb_gc_arena_save(mrb);

  for (uint64_t i = 0; i < len; i++) {
    mrb_value key = decode_value(mrb, r, src);
    mrb_value val = decode_value(mrb, r, src);
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
    case 23:
    case 24: return mrb_nil_value();

    /* ---------------------- Float16 ---------------------- */
    case 25: {
      uint16_t h =
        ((uint16_t)reader_read8(mrb, r) << 8) |
        ((uint16_t)reader_read8(mrb, r));

      uint16_t sign = h & 0x8000u;
      uint16_t exp  = h & 0x7C00u;
      uint16_t frac = h & 0x03FFu;

      uint32_t f;

      if (exp != 0) {
        uint32_t new_exp  = ((exp >> 10) + (127 - 15)) << 23;
        uint32_t new_frac = ((uint32_t)frac) << 13;
        f = ((uint32_t)sign << 16) | new_exp | new_frac;
      }
      else {
        if (frac == 0) {
          f = ((uint32_t)sign << 16);
        }
        else {
          uint32_t mant = frac;
          int shift = 0;
          while ((mant & 0x0400u) == 0) {
            mant <<= 1;
            shift++;
          }
          mant &= 0x03FFu;
          uint32_t new_exp  = (uint32_t)(127 - 15 - shift) << 23;
          uint32_t new_frac = mant << 13;
          f = ((uint32_t)sign << 16) | new_exp | new_frac;
        }
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

    case 31: mrb_raise(mrb, E_NOTIMP_ERROR, "indefinite-length items not supported in bounded mode");
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
    case 23:
    case 24:
      return mrb_nil_value();
    case 31: mrb_raise(mrb, E_NOTIMP_ERROR, "indefinite-length items not supported in bounded mode");
  }

  mrb_raise(mrb, E_NOTIMP_ERROR, "can't unpack floats or doubles since its disabled for this mruby runtime").
}
#endif

#ifdef MRB_USE_BIGINT
static void
increment_be(uint8_t* buf, size_t len)
{
  size_t i = len;
  while (i > 0) {
    i--;
    if (buf[i] != 0xFF) {
      buf[i] = (uint8_t)(buf[i] + 1);
      return;
    }
    buf[i] = 0x00;
  }
}

static mrb_value
decode_bignum_from_cbor_bytes(mrb_state* mrb,
                              const uint8_t* buf,
                              size_t len,
                              mrb_bool negative)
{
  /* 1) CBOR-Bytes kopieren (big-endian) */
  uint8_t* tmp = (uint8_t*)mrb_alloca(mrb, len);
  memcpy(tmp, buf, len);

  /* Tag 3: n -> n+1, damit value = -(n+1) = -1-n */
  if (negative) {
    increment_be(tmp, len);
  }

#ifndef MRB_ENDIAN_BIG
  /* MRuby läuft auf little-endian → Bytes umdrehen */
  for (size_t i = 0, j = len - 1; i < j; i++, j--) {
    uint8_t t = tmp[i];
    tmp[i] = tmp[j];
    tmp[j] = t;
  }
#endif

  /* Bytes → BigInt */
  mrb_value bn = mrb_bint_from_bytes(mrb, tmp, (mrb_int)len);

  /* Vorzeichen anwenden */
  if (negative) {
    return mrb_bint_neg(mrb, bn);   /* -(n+1) */
  }
  return bn;
}
#endif

// ============================================================================
// Master decode
// ============================================================================
static mrb_value
decode_value(mrb_state* mrb, Reader* r, mrb_value src)
{
  uint8_t b = reader_read8(mrb, r);
  uint8_t major = (uint8_t)(b >> 5);
  uint8_t info = (uint8_t)(b & 0x1F);


  switch (major) {
    case 0:
      return decode_unsigned(mrb, r, info);

    case 1:
      return decode_negative(mrb, r, info);

    case 2: return decode_bytes(mrb, r, src, info);
    case 3: return decode_text(mrb, r, src, info);

    case 4:
      return decode_array(mrb, r, src, info);

    case 5:
      return decode_map(mrb, r, src, info);

    case 6: {
      uint64_t tag = read_len(mrb, r, info);

#ifdef MRB_USE_BIGINT
      if (likely(tag == 2 || tag == 3)) {
        uint8_t b2 = reader_read8(mrb, r);
        uint8_t major2 = (uint8_t)(b2 >> 5);
        uint8_t info2  = (uint8_t)(b2 & 0x1F);

        if (likely(major2 == 2)) {
          uint64_t len = read_len(mrb, r, info2);
          size_t off   = reader_offset(r);
          ensure_slice_bounds(mrb, src, off, len);
          r->p        += len;

          const uint8_t* buf = (const uint8_t*)RSTRING_PTR(src) + off;
          mrb_bool negative  = (tag == 3);
          return decode_bignum_from_cbor_bytes(mrb, buf, (size_t)len, negative);
        }
      }
      mrb_raise(mrb, E_RUNTIME_ERROR, "invalid bignum payload");
      return mrb_undef_value();
#endif

      mrb_raise(mrb, E_NOTIMP_ERROR, "mruby was compiled without BigInt Support");
    }

    case 7:
      return decode_simple_or_float(mrb, r, info);
  }

  mrb_raise(mrb, E_RUNTIME_ERROR, "unknown major type");
  return mrb_nil_value();
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
  mrb_int arena_index;
} CborWriter;

static void
cbor_writer_init(CborWriter *w, mrb_state *mrb)
{
  w->mrb      = mrb;
  w->stack_len = 0;

  w->heap_str  = mrb_undef_value();
  w->heap_ptr  = NULL;
  w->heap_len  = 0;
  w->heap_capa = 0;
  w->arena_index = mrb_gc_arena_save(mrb);
}

static inline size_t next_pow2(size_t x)
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

  size_t initial = w->stack_len + need;
  size_t capa = next_pow2(initial);

  w->heap_str = mrb_str_new_capa(mrb, (mrb_int)capa);
  mrb_gc_protect(mrb, w->heap_str);
  w->arena_index = mrb_gc_arena_save(mrb);

  struct RString *s = RSTRING(w->heap_str);
  w->heap_ptr  = RSTR_PTR(s);
  w->heap_capa = (size_t)RSTR_CAPA(s);

  /* Stack → Heap kopieren */
  if (likely(w->stack_len > 0)) {
    memcpy(w->heap_ptr, w->stack_buf, w->stack_len);
    w->heap_len = w->stack_len;
  } else {
    w->heap_len = 0;
  }
}

static void
cbor_writer_ensure_heap(CborWriter *w, size_t add)
{
  size_t need = w->heap_len + add;
  if (need <= w->heap_capa) return;

  size_t capa = next_pow2(need);

  mrb_str_resize(w->mrb, w->heap_str, (mrb_int)capa);

  struct RString *s = RSTRING(w->heap_str);
  w->heap_ptr  = RSTR_PTR(s);
  w->heap_capa = (size_t)RSTR_CAPA(s);
}

static void
cbor_writer_write(CborWriter *w, const uint8_t *buf, size_t len)
{
  if (len == 0) return;

  /* Nur Stack? */
  if (likely(mrb_undef_p(w->heap_str) &&
      w->stack_len + len <= CBOR_SBO_STACK_CAP)) {

    memcpy(w->stack_buf + w->stack_len, buf, len);
    w->stack_len += len;
    return;
  }

  /* Heap initialisieren, falls noch nicht geschehen */
  if (mrb_undef_p(w->heap_str)) {
    cbor_writer_init_heap(w, len);
  }

  cbor_writer_ensure_heap(w, len);
  memcpy(w->heap_ptr + w->heap_len, buf, len);
  w->heap_len += len;
  mrb_gc_arena_restore(w->mrb, w->arena_index);
}

static void
cbor_writer_putc(CborWriter *w, uint8_t b)
{
  cbor_writer_write(w, &b, 1);
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

typedef CborWriter Writer;

static void
encode_len(Writer* w, uint8_t major, uint64_t len)
{
  uint8_t buf[1 + 8];   /* max: header + 8 bytes */
  size_t  n = 0;

  if (len < 24) {
    buf[0] = (uint8_t)((major << 5) | (uint8_t)len);
    n = 1;
  }
  else if (len <= 0xFFu) {
    buf[0] = (uint8_t)((major << 5) | 24);
    buf[1] = (uint8_t)len;
    n = 2;
  }
  else if (len <= 0xFFFFu) {
    buf[0] = (uint8_t)((major << 5) | 25);
    buf[1] = (uint8_t)(len >> 8);
    buf[2] = (uint8_t)(len);
    n = 3;
  }
  else if (len <= 0xFFFFFFFFu) {
    buf[0] = (uint8_t)((major << 5) | 26);
    buf[1] = (uint8_t)(len >> 24);
    buf[2] = (uint8_t)(len >> 16);
    buf[3] = (uint8_t)(len >> 8);
    buf[4] = (uint8_t)(len);
    n = 5;
  }
  else {
    buf[0] = (uint8_t)((major << 5) | 27);
    buf[1] = (uint8_t)(len >> 56);
    buf[2] = (uint8_t)(len >> 48);
    buf[3] = (uint8_t)(len >> 40);
    buf[4] = (uint8_t)(len >> 32);
    buf[5] = (uint8_t)(len >> 24);
    buf[6] = (uint8_t)(len >> 16);
    buf[7] = (uint8_t)(len >> 8);
    buf[8] = (uint8_t)(len);
    n = 9;
  }

  cbor_writer_write(w, buf, n);
}


// ============================================================================
// BigInt encoding (Tag 2/3) – mrb_bint_to_s ist native endian → korrigieren
// ============================================================================
#ifdef MRB_USE_BIGINT
static uint8_t
hex_nibble(char c)
{
  if (c >= '0' && c <= '9') return (uint8_t)(c - '0');
  if (c >= 'a' && c <= 'f') return (uint8_t)(c - 'a' + 10);
  if (c >= 'A' && c <= 'F') return (uint8_t)(c - 'A' + 10);
  return 0;
}

static void
encode_bignum(Writer* w, mrb_value obj)
{
  mrb_state* mrb = w->mrb;

  mrb_int sign = mrb_bint_sign(mrb, obj);

  /* Betrag holen */
  mrb_value mag = mrb_bint_abs(mrb, obj);

  /* Tag 3: n = |value| - 1 */
  if (sign < 0) {
    mrb_value one = mrb_fixnum_value(1);
    mag = mrb_bint_sub(mrb, mag, one);
  }

  /* Betrag (oder Betrag-1) als Hex */
  mrb_value hex = mrb_bint_to_s(mrb, mag, 16);
  const char* p = RSTRING_PTR(hex);
  mrb_int len = RSTRING_LEN(hex);

  /* ungerade Länge → führende 0 */
  mrb_bool odd = (len & 1);
  mrb_int nibs = odd ? (len + 1) : len;

  /* führende Null-Bytes bestimmen */
  mrb_int leading_zero_nibbles = 0;
  while (leading_zero_nibbles < len && p[leading_zero_nibbles] == '0')
    leading_zero_nibbles++;

  mrb_int off_bytes   = leading_zero_nibbles / 2;
  mrb_int total_bytes = nibs / 2;
  mrb_int final_len   = total_bytes - off_bytes;

  /* CBOR Tag */
  cbor_writer_putc(w, (sign < 0) ? 0xC3 : 0xC2);

  /* Länge */
  encode_len(w, 2, (uint64_t)final_len);

  /* Bytes direkt streamen */
  mrb_int si = 0;

  /* odd → erster Nibble ist low-only */
  if (odd) {
    uint8_t b = hex_nibble(p[0]);
    if (off_bytes == 0) cbor_writer_putc(w, b);
    si = 1;
  }

  mrb_int byte_index = odd ? 1 : 0;

  while (si < len) {
    uint8_t hi = hex_nibble(p[si++]);
    uint8_t lo = hex_nibble(p[si++]);
    uint8_t b  = (uint8_t)((hi << 4) | lo);

    if (byte_index >= off_bytes)
      cbor_writer_putc(w, b);

    byte_index++;
  }
}


#endif

// ============================================================================
// Array / Map
// ============================================================================
static void encode_value(Writer* w, mrb_value obj);

static void
encode_array(Writer* w, mrb_value ary)
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
  Writer *w = (Writer*)data;

  encode_value(w, key);
  encode_value(w, val);

  return 0; /* continue */
}

static void
encode_map(Writer* w, mrb_value hash)
{
  mrb_state *mrb = w->mrb;
  struct RHash *h = mrb_hash_ptr(hash);

  /* Anzahl der Paare */
  mrb_int len = mrb_hash_size(mrb, hash);
  encode_len(w, 5, (uint64_t)len);

  /* direkte Iteration über Hash-Table */
  mrb_hash_foreach(mrb, h, encode_map_foreach, w);
}


// ============================================================================
// Text
// ============================================================================
static void
encode_string(Writer* w, mrb_value str)
{
  const char* p = RSTRING_PTR(str);
  mrb_int blen  = RSTRING_LEN(str);

  if (mrb_str_is_utf8(str)) {
    /* UTF‑8 → CBOR Text (Major 3) */
    encode_len(w, 3, (uint64_t)blen);
  } else {
    /* Nicht UTF‑8 → CBOR Bytes (Major 2) */
    encode_len(w, 2, (uint64_t)blen);
  }

  cbor_writer_write(w, (const uint8_t*)p, (size_t)blen);
}

// ============================================================================
// Simple
// ============================================================================
static void
encode_simple(Writer* w, mrb_value obj)
{
  uint8_t b;

  if (mrb_nil_p(obj)) {
    b = 0xF6;
  }
  else if (!mrb_bool(obj)) {
    b = 0xF4;
  }
  else {
    b = 0xF5;
  }

  cbor_writer_write(w, &b, 1);
}

static void
encode_integer(Writer *w, mrb_int n)
{
  uint8_t buf[1 + 8];
  size_t  nbytes = 0;
  uint8_t major;
  uint64_t v;

  if (n >= 0) {
    major = 0;
    v = (uint64_t)n;
  }
  else {
    major = 1;
    v = (uint64_t)(-1 - n);
  }

  if (v < 24) {
    buf[0] = (uint8_t)((major << 5) | (uint8_t)v);
    nbytes = 1;
  }
  else if (v <= 0xFFu) {
    buf[0] = (uint8_t)((major << 5) | 24);
    buf[1] = (uint8_t)v;
    nbytes = 2;
  }
  else if (v <= 0xFFFFu) {
    buf[0] = (uint8_t)((major << 5) | 25);
    buf[1] = (uint8_t)(v >> 8);
    buf[2] = (uint8_t)(v);
    nbytes = 3;
  }
  else if (v <= 0xFFFFFFFFu) {
    buf[0] = (uint8_t)((major << 5) | 26);
    buf[1] = (uint8_t)(v >> 24);
    buf[2] = (uint8_t)(v >> 16);
    buf[3] = (uint8_t)(v >> 8);
    buf[4] = (uint8_t)(v);
    nbytes = 5;
  }
  else {
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


#ifndef MRB_NO_FLOAT
static void
encode_float(Writer *w, mrb_float f)
{
#ifdef MRB_USE_FLOAT32
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
  uint8_t buf[1 + 8];
  buf[0] = 0xFB;
  double d = (double)f;
  uint64_t u;
  memcpy(&u, &d, sizeof(uint64_t));
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
encode_value(Writer* w, mrb_value obj)
{
  mrb_state* mrb = w->mrb;

  switch (mrb_type(obj)) {
    case MRB_TT_FALSE:
    case MRB_TT_TRUE:
      encode_simple(w, obj);
      return;

    case MRB_TT_INTEGER:
      encode_integer(w, mrb_integer(obj));
      return;

#ifndef MRB_NO_FLOAT
  case MRB_TT_FLOAT:
    encode_float(w, mrb_float(obj));
    return;
#endif

    case MRB_TT_STRING:
      encode_string(w, obj);
      return;

    case MRB_TT_ARRAY:
      encode_array(w, obj);
      return;

    case MRB_TT_HASH:
      encode_map(w, obj);
      return;

#ifdef MRB_USE_BIGINT
    case MRB_TT_BIGINT:
      encode_bignum(w, obj);
      return;
#endif

    default: {
      mrb_value s = mrb_obj_as_string(mrb, obj);
      encode_string(w, s);
      return;
    }
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

  mrb_get_args(mrb, "o", &obj);

  CborWriter w;
  cbor_writer_init(&w, mrb);
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

  mrb_value obj = decode_value(mrb, &r, src);

  if (!reader_eof(&r)) {
    mrb_raise(mrb, E_RUNTIME_ERROR, "extra bytes after CBOR document");
  }

  return obj;
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
cbor_lazy_new(mrb_state *mrb, mrb_value buf, uint32_t offset)
{
  struct RClass *cbor = mrb_module_get_id(mrb, MRB_SYM(CBOR));
  struct RClass *lazy = mrb_class_get_under_id(mrb, cbor, MRB_SYM(Lazy));

  cbor_lazy_t *p;
  struct RData *data;
  Data_Make_Struct(mrb, lazy, cbor_lazy_t, &cbor_lazy_type, p, data);

  p->buf    = buf;
  p->offset = offset;
  mrb_value obj = mrb_obj_value(data);
  mrb_iv_set(mrb, obj, MRB_SYM(buf), buf);
  mrb_iv_set(mrb, obj, MRB_SYM(vcache), mrb_undef_value());
  mrb_iv_set(mrb, obj, MRB_SYM(kcache), mrb_hash_new(mrb));
  return obj;
}

static void
skip_cbor(mrb_state *mrb, Reader *r)
{
  if (unlikely(r->p >= r->end)) {
    mrb_raise(mrb, E_RUNTIME_ERROR, "unexpected end of buffer");
  }

  uint8_t b = reader_read8(mrb, r);
  uint8_t major = b >> 5;
  uint8_t info  = b & 0x1F;

  switch (major) {

    case 0: /* unsigned integer */
    case 1: /* negative integer */
      if (info < 24) {
        return;
      }
      /* read_num advances r->p for extended integer encodings */
      read_num(mrb, r, info);
      return;

    case 2: /* byte string */
    case 3: { /* text string */
      uint64_t len = read_len(mrb, r, info);
      if ((uint64_t)(r->end - r->p) < len) {
        mrb_raise(mrb, E_RUNTIME_ERROR, "CBOR string out of bounds");
      }
      r->p += len;
      return;
    }

    case 4: { /* array */
      uint64_t len = read_len(mrb, r, info);
      for (uint64_t i = 0; i < len; i++) {
        skip_cbor(mrb, r);
      }
      return;
    }

    case 5: { /* map */
      uint64_t len = read_len(mrb, r, info);
      for (uint64_t i = 0; i < len; i++) {
        skip_cbor(mrb, r); /* key */
        skip_cbor(mrb, r); /* value */
      }
      return;
    }

    case 6: { /* tag */
      /* skip tag number then the tagged item */
      read_len(mrb, r, info);
      skip_cbor(mrb, r);
      return;
    }

    case 7: { /* simple / float / break */
      if (info < 24) return;

      switch (info) {
        case 24:
          if (likely(r->p < r->end)) { r->p++; return; }
          mrb_raise(mrb, E_RUNTIME_ERROR, "simple value out of bounds");
        case 25:
          if (likely((r->end - r->p) >= 2)) { r->p += 2; return; }
          mrb_raise(mrb, E_RUNTIME_ERROR, "float16 out of bounds");
        case 26:
          if (likely((r->end - r->p) >= 4)) { r->p += 4; return; }
          mrb_raise(mrb, E_RUNTIME_ERROR, "float32 out of bounds");
        case 27:
          if (likely((r->end - r->p) >= 8)) { r->p += 8; return; }
          mrb_raise(mrb, E_RUNTIME_ERROR, "float64 out of bounds");
        case 31: mrb_raise(mrb, E_NOTIMP_ERROR, "indefinite-length items not supported in bounded mode");
      }
    }
  }

  mrb_raise(mrb, E_RUNTIME_ERROR, "invalid CBOR major type");
}


/* Lazy#value: vollständiges Dekodieren ab Element-Header (p->offset muss auf Header zeigen) */
static mrb_value
cbor_lazy_value(mrb_state *mrb, mrb_value self)
{
  mrb_value vcache = mrb_iv_get(mrb, self, MRB_SYM(vcache));
  if (!mrb_undef_p(vcache)) return vcache;

  cbor_lazy_t *p = DATA_PTR(self);

  const uint8_t *base = (const uint8_t*)RSTRING_PTR(p->buf);
  size_t total_len    = (size_t)RSTRING_LEN(p->buf);

  if (unlikely(p->offset >= total_len)) {
    mrb_raise(mrb, E_RUNTIME_ERROR, "lazy offset out of bounds");
  }

  Reader r;
  r.base = base;
  r.p    = base + p->offset;
  r.end  = base + total_len;


  mrb_value value = decode_value(mrb, &r, p->buf);
  mrb_iv_set(mrb, self, MRB_SYM(vcache), value);
  return value;
}

static mrb_value
cbor_lazy_aref(mrb_state *mrb, mrb_value self)
{
  cbor_lazy_t *p = DATA_PTR(self);
  mrb_value key;
  mrb_get_args(mrb, "o", &key);
  mrb_value kcache = mrb_iv_get(mrb, self, MRB_SYM(kcache));
  mrb_value cached_key = mrb_hash_fetch(mrb, kcache, key, mrb_undef_value());
  if (!mrb_undef_p(cached_key)) return cached_key;

  const uint8_t *base = (const uint8_t*)RSTRING_PTR(p->buf);
  size_t total_len    = (size_t)RSTRING_LEN(p->buf);

  if (unlikely(p->offset >= total_len)) {
    mrb_raise(mrb, E_RUNTIME_ERROR, "lazy offset out of bounds");
  }

  Reader r;
  /* WICHTIG: wie bei cbor_lazy_value – base ist immer der Anfang des gesamten Buffers */
  r.base = base;
  r.p    = base + p->offset;
  r.end  = base + total_len;

  uint8_t b    = reader_read8(mrb, &r);
  uint8_t major = (uint8_t)(b >> 5);
  uint8_t info  = (uint8_t)(b & 0x1F);

  switch (major) {
    case 4: { /* Array */
      mrb_value normalized_key = mrb_ensure_int_type(mrb, key);

      mrb_int idx = mrb_integer(normalized_key);
      uint64_t len = read_len(mrb, &r, info);

      if (idx < 0) idx += (mrb_int)len;
      if ((uint64_t)idx >= len || idx < 0) {
        return mrb_nil_value();
      }

      for (mrb_int i = 0; i < idx; i++) {
        skip_cbor(mrb, &r);
      }

      uint32_t elem_offset = (uint32_t)(r.p - base);
      mrb_value new_lazy = cbor_lazy_new(mrb, p->buf, elem_offset);
      mrb_hash_set(mrb, kcache, key, new_lazy);
      return new_lazy;
    }

    case 5: { /* Map */
      uint64_t pairs = read_len(mrb, &r, info);

      for (uint64_t i = 0; i < pairs; i++) {
        /* Key vollständig decodieren */
        mrb_value decoded_key = decode_value(mrb, &r, p->buf);

        /* Value beginnt jetzt an r.p */
        uint32_t value_offset = (uint32_t)(r.p - base);

        if (mrb_equal(mrb, decoded_key, key)) {
          mrb_value lazy_new = cbor_lazy_new(mrb, p->buf, value_offset);
          mrb_hash_set(mrb, kcache, key, lazy_new);
          return lazy_new;
        }

        /* Value überspringen, wenn Key nicht passt */
        skip_cbor(mrb, &r);
      }

      return mrb_nil_value();
    }

    default:
      mrb_raise(mrb, E_TYPE_ERROR, "not indexable");
  }

  return mrb_undef_value(); /* unreachable */
}

static mrb_value
mrb_cbor_decode_lazy(mrb_state *mrb, mrb_value self)
{
  mrb_value buf;
  mrb_get_args(mrb, "S", &buf);

  return cbor_lazy_new(mrb, mrb_str_byte_subseq(mrb, buf, 0, RSTRING_LEN(buf)), 0);
}

MRB_BEGIN_DECL

void
mrb_mruby_cbor_gem_init(mrb_state* mrb)
{
  struct RClass* mod = mrb_define_module_id(mrb, MRB_SYM(CBOR));

  mrb_define_module_function_id(mrb, mod, MRB_SYM(decode), mrb_cbor_decode, MRB_ARGS_REQ(1));
  mrb_define_module_function_id(mrb, mod, MRB_SYM(encode), mrb_cbor_encode, MRB_ARGS_REQ(1));

  struct RClass *lazy = mrb_define_class_under_id(mrb, mod, MRB_SYM(Lazy), mrb->object_class);
  MRB_SET_INSTANCE_TT(lazy, MRB_TT_DATA);

  mrb_define_method_id(mrb, lazy, MRB_OPSYM(aref),    cbor_lazy_aref,  MRB_ARGS_REQ(1));
  mrb_define_method_id(mrb, lazy, MRB_SYM(value), cbor_lazy_value, MRB_ARGS_NONE());

  mrb_define_module_function_id(mrb, mod, MRB_SYM(decode_lazy),
                                mrb_cbor_decode_lazy, MRB_ARGS_REQ(1));
}


void
mrb_mruby_cbor_gem_final(mrb_state* mrb)
{
  (void)mrb;
}

MRB_END_DECL
