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

#include <stdint.h>
#include <stddef.h>
#include <string.h>


/* ============================================================
 * scalar fallback
 * ============================================================ */

static inline uint8_t hex_nibble_scalar(char c)
{
    if (c >= '0' && c <= '9') return (uint8_t)(c - '0');
    if (c >= 'a' && c <= 'f') return (uint8_t)(c - 'a' + 10);
    if (c >= 'A' && c <= 'F') return (uint8_t)(c - 'A' + 10);
    return 0;
}

static inline void hex_decode_scalar(uint8_t *out, const char *in, size_t len)
{
    for (size_t i = 0; i < len; i += 2) {
        uint8_t hi = hex_nibble_scalar(in[i]);
        uint8_t lo = hex_nibble_scalar(in[i+1]);
        out[i/2] = (uint8_t)((hi << 4) | lo);
    }
}

/* ============================================================
 * portable CPUID wrapper (nur auf x86!)
 * ============================================================ */

#if defined(__x86_64__) || defined(_M_X64) || defined(__i386__) || defined(_M_IX86)

# if defined(_MSC_VER)
#  include <intrin.h>
   static inline void cpuid(int out[4], int leaf, int subleaf) {
       __cpuidex(out, leaf, subleaf);
   }
# else
#  include <cpuid.h>
   static inline void cpuid(int out[4], int leaf, int subleaf) {
       __cpuid_count(leaf, subleaf, out[0], out[1], out[2], out[3]);
   }
# endif

#endif /* x86 */

/* ============================================================
 * SSE2 detection
 * ============================================================ */

static inline int cpu_has_sse2(void)
{
#if defined(__x86_64__) || defined(_M_X64)
    return 1;
#elif defined(__i386__) || defined(_M_IX86)
    int r[4];
    cpuid(r, 1, 0);
    return (r[3] & (1 << 26)) != 0;
#else
    return 0;
#endif
}

/* ============================================================
 * AVX / AVX2 detection
 * ============================================================ */

static inline int cpu_has_avx(void)
{
#if defined(__x86_64__) || defined(_M_X64) || defined(__i386__) || defined(_M_IX86)
    int r[4];
    cpuid(r, 1, 0);

    int os_uses_xsave_xrstore = (r[2] & (1 << 27)) != 0;
    int cpu_avx_support       = (r[2] & (1 << 28)) != 0;

    if (!(os_uses_xsave_xrstore && cpu_avx_support))
        return 0;

# if defined(_MSC_VER)
    unsigned long long xcr = _xgetbv(0);
# else
    unsigned eax, edx;
    __asm__ volatile("xgetbv" : "=a"(eax), "=d"(edx) : "c"(0));
    unsigned long long xcr = ((unsigned long long)edx << 32) | eax;
# endif

    return (xcr & 0x6) == 0x6;
#else
    return 0;
#endif
}

static inline int cpu_has_avx2(void)
{
#if defined(__x86_64__) || defined(_M_X64) || defined(__i386__) || defined(_M_IX86)
    if (!cpu_has_avx()) return 0;
    int r[4];
    cpuid(r, 7, 0);
    return (r[1] & (1 << 5)) != 0;
#else
    return 0;
#endif
}

/* ============================================================
 * NEON detection (ohne Linux-Header)
 * ============================================================ */

#if defined(__aarch64__) || defined(__ARM_NEON)
# include <arm_neon.h>
#endif

static inline int cpu_has_neon(void)
{
#if defined(__aarch64__)
    return 1;
#elif defined(__ARM_NEON)
    return 1;
#else
    return 0;
#endif
}

/* ============================================================
 * SIMD dispatch pointer
 * ============================================================ */

typedef void (*hex_decode_fn)(uint8_t *out, const char *in, size_t len);
static hex_decode_fn hex_decode_impl = hex_decode_scalar;

#if defined(__SSE2__)
#include <emmintrin.h>

static inline __m128i hex_to_nibble_sse2(__m128i c)
{
    __m128i zero = _mm_set1_epi8('0');
    __m128i nine = _mm_set1_epi8('9');
    __m128i A    = _mm_set1_epi8('A');
    __m128i F    = _mm_set1_epi8('F');
    __m128i a    = _mm_set1_epi8('a');
    __m128i f    = _mm_set1_epi8('f');
    __m128i ten  = _mm_set1_epi8(10);

    __m128i val0 = _mm_sub_epi8(c, zero);
    __m128i valA = _mm_add_epi8(_mm_sub_epi8(c, A), ten);
    __m128i vala = _mm_add_epi8(_mm_sub_epi8(c, a), ten);

    __m128i is_digit = _mm_and_si128(_mm_cmpgt_epi8(c, _mm_sub_epi8(zero,_mm_set1_epi8(1))),
                                     _mm_cmplt_epi8(c, _mm_add_epi8(nine,_mm_set1_epi8(1))));
    __m128i is_upper = _mm_and_si128(_mm_cmpgt_epi8(c, _mm_sub_epi8(A,_mm_set1_epi8(1))),
                                     _mm_cmplt_epi8(c, _mm_add_epi8(F,_mm_set1_epi8(1))));
    __m128i is_lower = _mm_and_si128(_mm_cmpgt_epi8(c, _mm_sub_epi8(a,_mm_set1_epi8(1))),
                                     _mm_cmplt_epi8(c, _mm_add_epi8(f,_mm_set1_epi8(1))));

    __m128i res = _mm_and_si128(is_digit, val0);
    res = _mm_or_si128(res, _mm_and_si128(is_upper, valA));
    res = _mm_or_si128(res, _mm_and_si128(is_lower, vala));

    return res;
}

static inline void hex_decode_sse2(uint8_t *out, const char *in, size_t len)
{
    size_t i = 0;

    for (; i + 32 <= len; i += 32) {
        __m128i c0 = _mm_loadu_si128((const __m128i*)(in + i));
        __m128i c1 = _mm_loadu_si128((const __m128i*)(in + i + 16));

        // unpack hi/lo nibbles
        __m128i hi_nibble = hex_to_nibble_sse2(_mm_unpacklo_epi8(c0, c1));
        __m128i lo_nibble = hex_to_nibble_sse2(_mm_unpackhi_epi8(c0, c1));

        // shift hi nibble
        __m128i hi_shifted = _mm_slli_epi16(hi_nibble, 4);

        // combine
        __m128i bytes = _mm_or_si128(hi_shifted, lo_nibble);

        // pack 16-bit -> 8-bit
        bytes = _mm_packus_epi16(bytes, _mm_setzero_si128());

        _mm_storeu_si128((__m128i*)(out + i/2), bytes);
    }

    if (i < len)
        hex_decode_scalar(out + i/2, in + i, len - i);
}

#endif /* SSE2 */

/* ============================================================
 * AVX2 implementation (256-bit)
 * ============================================================ */

#if defined(__AVX2__)
#include <immintrin.h>

static inline __m256i hex_to_nibble_avx2(__m256i c)
{
    __m256i zero = _mm256_set1_epi8('0');
    __m256i nine = _mm256_set1_epi8('9');
    __m256i A    = _mm256_set1_epi8('A');
    __m256i F    = _mm256_set1_epi8('F');
    __m256i a    = _mm256_set1_epi8('a');
    __m256i f    = _mm256_set1_epi8('f');
    __m256i ten  = _mm256_set1_epi8(10);

    __m256i val0 = _mm256_sub_epi8(c, zero);
    __m256i valA = _mm256_sub_epi8(c, A);
    __m256i vala = _mm256_sub_epi8(c, a);

    __m256i ge_zero = _mm256_cmpeq_epi8(c, _mm256_max_epu8(c, zero));
    __m256i le_nine = _mm256_cmpeq_epi8(c, _mm256_min_epu8(c, nine));
    __m256i is_digit = _mm256_and_si256(ge_zero, le_nine);

    __m256i ge_A = _mm256_cmpeq_epi8(c, _mm256_max_epu8(c, A));
    __m256i le_F = _mm256_cmpeq_epi8(c, _mm256_min_epu8(c, F));
    __m256i is_upper = _mm256_and_si256(ge_A, le_F);

    __m256i ge_a = _mm256_cmpeq_epi8(c, _mm256_max_epu8(c, a));
    __m256i le_f = _mm256_cmpeq_epi8(c, _mm256_min_epu8(c, f));
    __m256i is_lower = _mm256_and_si256(ge_a, le_f);

    __m256i res = _mm256_and_si256(is_digit, val0);
    res = _mm256_or_si256(res,
                          _mm256_and_si256(is_upper, _mm256_add_epi8(valA, ten)));
    res = _mm256_or_si256(res,
                          _mm256_and_si256(is_lower, _mm256_add_epi8(vala, ten)));

    return res;
}

static inline void hex_decode_avx2(uint8_t *out, const char *in, size_t len)
{
    const __m256i mul = _mm256_setr_epi8(
        0x10,1, 0x10,1, 0x10,1, 0x10,1,
        0x10,1, 0x10,1, 0x10,1, 0x10,1,
        0x10,1, 0x10,1, 0x10,1, 0x10,1,
        0x10,1, 0x10,1, 0x10,1, 0x10,1
    );

    size_t i = 0;

    for (; i + 32 <= len; i += 32) {
        __m256i ascii = _mm256_loadu_si256((const __m256i*)(in + i));
        __m256i n     = hex_to_nibble_avx2(ascii);
        __m256i words = _mm256_maddubs_epi16(n, mul); // 16x16-bit

        // Lane 0
        __m128i w0 = _mm256_castsi256_si128(words);
        __m128i b0 = _mm_packus_epi16(w0, w0);        // 8 Bytes in low 8
        _mm_storel_epi64((__m128i*)(out + i/2), b0);

        // Lane 1
        __m128i w1 = _mm256_extracti128_si256(words, 1);
        __m128i b1 = _mm_packus_epi16(w1, w1);
        _mm_storel_epi64((__m128i*)(out + i/2 + 8), b1);
    }

    if (i < len) {
        hex_decode_scalar(out + i/2, in + i, len - i);
    }
}


#endif /* AVX2 */

/* ============================================================
 * NEON implementation
 * ============================================================ */

#if defined(__ARM_NEON) || defined(__aarch64__)

static inline uint8x16_t hex_to_nibble_neon(uint8x16_t c)
{
    uint8x16_t zero = vdupq_n_u8('0');
    uint8x16_t nine = vdupq_n_u8('9');
    uint8x16_t A    = vdupq_n_u8('A');
    uint8x16_t F    = vdupq_n_u8('F');
    uint8x16_t a    = vdupq_n_u8('a');
    uint8x16_t f    = vdupq_n_u8('f');
    uint8x16_t ten  = vdupq_n_u8(10);

    uint8x16_t val0 = vsubq_u8(c, zero);
    uint8x16_t valA = vsubq_u8(c, A);
    uint8x16_t vala = vsubq_u8(c, a);

    uint8x16_t is_digit = vandq_u8(vcgeq_u8(c, zero), vcleq_u8(c, nine));
    uint8x16_t is_upper = vandq_u8(vcgeq_u8(c, A),    vcleq_u8(c, F));
    uint8x16_t is_lower = vandq_u8(vcgeq_u8(c, a),    vcleq_u8(c, f));

    uint8x16_t res = vandq_u8(is_digit, val0);
    res = vorrq_u8(res, vandq_u8(is_upper, vaddq_u8(valA, ten)));
    res = vorrq_u8(res, vandq_u8(is_lower, vaddq_u8(vala, ten)));
    return res;
}

static inline void hex_decode_neon(uint8_t *out, const char *in, size_t len)
{
    size_t i = 0;

    for (; i + 32 <= len; i += 32) {
        uint8x16_t ascii0 = vld1q_u8((const uint8_t*)(in + i));
        uint8x16_t ascii1 = vld1q_u8((const uint8_t*)(in + i + 16));

        uint8x16_t hi_ascii = vuzp1q_u8(ascii0, ascii1);
        uint8x16_t lo_ascii = vuzp2q_u8(ascii0, ascii1);

        uint8x16_t hi = hex_to_nibble_neon(hi_ascii);
        uint8x16_t lo = hex_to_nibble_neon(lo_ascii);

        uint8x16_t hi_shift = vshlq_n_u8(hi, 4);
        uint8x16_t bytes    = vorrq_u8(hi_shift, lo);

        vst1q_u8(out + i/2, bytes);
    }

    if (i < len)
        hex_decode_scalar(out + i/2, in + i, len - i);
}

#endif /* NEON */

/* ============================================================
 * dispatch
 * ============================================================ */

static inline void hex_decode_init(void)
{
#if defined(__AVX2__)
    if (cpu_has_avx2()) { hex_decode_impl = hex_decode_avx2; return; }
#endif
#if defined(__x86_64__) || defined(__i386__) || defined(_M_X64) || defined(_M_IX86)
    if (cpu_has_sse2()) { hex_decode_impl = hex_decode_sse2; return; }
#endif
#if defined(__ARM_NEON) || defined(__aarch64__)
    if (cpu_has_neon()) { hex_decode_impl = hex_decode_neon; return; }
#endif
    hex_decode_impl = hex_decode_scalar;
}

static inline void hex_decode(uint8_t *out, const char *in, size_t len)
{
    hex_decode_impl(out, in, len);
}


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
    case 31: mrb_raise(mrb, E_NOTIMP_ERROR, "indefinite-length items not supported in bounded mode");
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
  size_t slen = (size_t)RSTRING_LEN(src);

  /* Fast path: alles im gueltigen Bereich, ohne Overflow-Risiko */
  if (likely(off <= slen && len <= slen - off)) {
    return;
  }

  /* Slow path: irgendwas ist out of bounds */
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
      mrb_raise(mrb, E_RUNTIME_ERROR, "text string out of bounds");
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
      mrb_raise(mrb, E_RUNTIME_ERROR, "text string out of bounds");
  }

  return mrb_nil_value();
}

static mrb_value decode_value(mrb_state* mrb, Reader* r, mrb_value src, mrb_value shareable);
/* shareable: mrb_undef_value() = eager mode (no shared refs), mrb_hash = lazy shared-ref table */

static mrb_value
decode_array(mrb_state* mrb, Reader* r, mrb_value src, uint8_t info, mrb_value shareable, mrb_int share_idx)
{
  uint64_t len = read_len(mrb, r, info);
  mrb_value ary = mrb_ary_new_capa(mrb, (mrb_int)len);

  if (likely(share_idx >= 0))
    mrb_hash_set(mrb, shareable, mrb_int_value(mrb, share_idx), ary);

  mrb_int idx = mrb_gc_arena_save(mrb);

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
  mrb_value hash = mrb_hash_new_capa(mrb, (mrb_int)len);

  if (likely(share_idx >= 0))
    mrb_hash_set(mrb, shareable, mrb_int_value(mrb, share_idx), hash);

  mrb_int idx = mrb_gc_arena_save(mrb);

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
static mrb_value
decode_bignum_from_cbor_bytes(mrb_state* mrb,
                              const uint8_t* buf,
                              size_t len,
                              mrb_bool negative)
{
  if (len == 0) return mrb_fixnum_value(negative ? -1 : 0);
  mrb_int idx = mrb_gc_arena_save(mrb);
  uint8_t *tmp = mrb_alloca(mrb, len);
  memcpy(tmp, buf, len);

#ifndef MRB_ENDIAN_BIG
  /* 2) Fuer MRuby in little-endian drehen */
  for (size_t i = 0, j = len - 1; i < j; i++, j--) {
    uint8_t t = tmp[i];
    tmp[i] = tmp[j];
    tmp[j] = t;
  }
#endif

  /* 3) Bytes -> positiver BigInt n */
  mrb_value n = mrb_bint_from_bytes(mrb, tmp, (mrb_int)len);
  mrb_gc_arena_restore(mrb, idx);
  mrb_gc_protect(mrb, n);
  if (!negative) {
    return n; /* Tag 2 */
  }

  /* 4) Tag 3: value = -1 - n  */

  /* n_plus_1 = n + 1 */
  mrb_value one = mrb_fixnum_value(1);
  mrb_value n_plus_1 = mrb_bint_add(mrb, n, one);

  /* result = -(n+1) */
  mrb_value result = mrb_bint_neg(mrb, n_plus_1);
  mrb_gc_arena_restore(mrb, idx);
  mrb_gc_protect(mrb, result);
  return result;
}

#endif

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
    case 0:
      return decode_unsigned(mrb, r, info);

    case 1:
      return decode_negative(mrb, r, info);

    case 2: return decode_bytes(mrb, r, src, info);
    case 3: return decode_text(mrb, r, src, info);

    case 4:
      return decode_array(mrb, r, src, info, shareable, -1);

    case 5:
      return decode_map(mrb, r, src, info, shareable, -1);

    case 6: {
      uint64_t tag = read_len(mrb, r, info);

      switch (tag) {
        case 2:
        case 3: {
#ifdef MRB_USE_BIGINT
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
          mrb_raise(mrb, E_RUNTIME_ERROR, "invalid bignum payload");

#else
          mrb_raise(mrb, E_NOTIMP_ERROR, "mruby was compiled without BigInt Support");
#endif
        } break;

        /* ---- Tag 28: shareable ---- */
        case 28: {
          if (likely(mrb_hash_p(shareable))) {
            mrb_int share_idx = mrb_hash_size(mrb, shareable);
            mrb_value idx_key = mrb_int_value(mrb, share_idx);

            /* Peek: naechstes Byte bestimmt ob Array oder Map -
               dann koennen wir den Container vor dem Befuellen registrieren */
            uint8_t nb     = reader_read8(mrb, r);
            uint8_t major2 = nb >> 5;
            uint8_t info2  = nb & 0x1F;

            if (likely(major2 == 4))
              return decode_array(mrb, r, src, info2, shareable, share_idx);

            if (likely(major2 == 5))
              return decode_map(mrb, r, src, info2, shareable, share_idx);

            /* Skalare: erst dekodieren, dann registrieren */
            mrb_hash_set(mrb, shareable, idx_key, mrb_undef_value());
            mrb_value inner;
            switch (major2) {
              case 0: inner = decode_unsigned(mrb, r, info2); break;
              case 1: inner = decode_negative(mrb, r, info2); break;
              case 2: inner = decode_bytes(mrb, r, src, info2); break;
              case 3: inner = decode_text(mrb, r, src, info2); break;
              case 6: { read_len(mrb, r, info2); inner = decode_value(mrb, r, src, shareable); break; }
              case 7: inner = decode_simple_or_float(mrb, r, info2); break;
              default:
                mrb_raise(mrb, E_RUNTIME_ERROR, "unknown major type in shareable");
                inner = mrb_undef_value();
            }
            mrb_hash_set(mrb, shareable, idx_key, inner);
            return inner;
          } else {
            return decode_value(mrb, r, src, shareable);
          }
        }

        /* ---- Tag 29: sharedref ---- */
        case 29: {
          if (likely(mrb_hash_p(shareable))) {
            uint8_t ref_b     = reader_read8(mrb, r);
            uint8_t ref_major = ref_b >> 5;
            uint8_t ref_info  = ref_b & 0x1F;

            if (likely(ref_major == 0)) {
              mrb_value key    = mrb_convert_uint64(mrb, read_len(mrb, r, ref_info));
              mrb_value found  = mrb_hash_fetch(mrb, shareable, key, mrb_undef_value());

              if (likely(!mrb_undef_p(found))) return found;
              else mrb_raisef(mrb, E_RUNTIME_ERROR, "sharedref index %v not found", key);
            } else {
              mrb_raise(mrb, E_RUNTIME_ERROR, "sharedref payload must be unsigned integer");
            }
          } else {
            mrb_raise(mrb, E_RUNTIME_ERROR, "sharedref (tag 29) outside lazy context");
          }
        }

      }
      return mrb_undef_value();

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
  mrb_raise(mrb, E_RUNTIME_ERROR, "stack size overflow");
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
    mrb_raise(mrb, E_RUNTIME_ERROR, "heap size overflow");
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
          mrb_raise(mrb, E_RUNTIME_ERROR, "stack size overflow");
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
  hex_decode(out, p, nibs);
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

#ifndef MRB_NO_FLOAT
static void
encode_float(CborWriter *w, mrb_float f)
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
encode_value(CborWriter* w, mrb_value obj)
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
      mrb_raise(mrb, E_RUNTIME_ERROR, "CBOR string out of bounds");
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

      if (likely(mrb_hash_p(shareable))) {
        if (tag == 28) {
          /* inner item offset - register as Lazy before skipping */
          mrb_int share_idx = mrb_hash_size(mrb, shareable);
          uint32_t inner_offset = (uint32_t)(r->p - r->base);
          mrb_value lazy = cbor_lazy_new(mrb, buf, inner_offset, shareable);
          mrb_hash_set(mrb, shareable, mrb_int_value(mrb, share_idx), lazy);
          skip_cbor(mrb, r, buf, shareable);
          return;
        }
        /* tag 29: just skip the uint index, nothing to register */
      }

      skip_cbor(mrb, r, buf, shareable);
      return;
    }

    case 7: {
      if (info < 24) return;
      switch (info) {
        case 24: if (likely(r->p < r->end)) { r->p++; return; }
                 mrb_raise(mrb, E_RUNTIME_ERROR, "simple value out of bounds");
        case 25: if (likely((r->end - r->p) >= 2)) { r->p += 2; return; }
                 mrb_raise(mrb, E_RUNTIME_ERROR, "float16 out of bounds");
        case 26: if (likely((r->end - r->p) >= 4)) { r->p += 4; return; }
                 mrb_raise(mrb, E_RUNTIME_ERROR, "float32 out of bounds");
        case 27: if (likely((r->end - r->p) >= 8)) { r->p += 8; return; }
                 mrb_raise(mrb, E_RUNTIME_ERROR, "float64 out of bounds");
        case 31: mrb_raise(mrb, E_NOTIMP_ERROR, "indefinite-length items not supported in bounded mode");
      }
    }
  }

  mrb_raisef(mrb, E_NOTIMP_ERROR, "Not implemented CBOR major type '%d'", major);
}


/* Lazy#value: vollstaendiges Dekodieren ab Element-Header (p->offset muss auf Header zeigen) */
static mrb_value
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
    mrb_raise(mrb, E_RUNTIME_ERROR, "lazy offset out of bounds");
    return mrb_undef_value();
  }
}

static mrb_value
cbor_lazy_aref(mrb_state *mrb, mrb_value self)
{
  cbor_lazy_t *p = DATA_PTR(self);
  mrb_value key;
  mrb_get_args(mrb, "o", &key);
  mrb_value kcache = mrb_iv_get(mrb, self, MRB_SYM(kcache));
  if (likely(mrb_hash_p(kcache))) {
    mrb_value cached_key = mrb_hash_fetch(mrb, kcache, key, mrb_undef_value());
    if (!mrb_undef_p(cached_key)) return cached_key;
  } else {
    mrb_raise(mrb, E_TYPE_ERROR, "kcache is not a hash");
  }

  const uint8_t *base = (const uint8_t*)RSTRING_PTR(p->buf);
  size_t total_len    = (size_t)RSTRING_LEN(p->buf);

  if (unlikely(p->offset >= total_len)) {
    mrb_raise(mrb, E_RUNTIME_ERROR, "lazy offset out of bounds");
  }

  mrb_value shareable = mrb_iv_get(mrb, self, MRB_SYM(shareable));

  Reader r;
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
        skip_cbor(mrb, &r, p->buf, shareable);
      }

      uint32_t elem_offset = (uint32_t)(r.p - base);
      mrb_value new_lazy = cbor_lazy_new(mrb, p->buf, elem_offset, shareable);
      mrb_hash_set(mrb, kcache, key, new_lazy);
      return new_lazy;
    }

    case 5: { /* Map */
      uint64_t pairs = read_len(mrb, &r, info);
      mrb_bool key_is_str = mrb_string_p(key);

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
          uint32_t value_offset = (uint32_t)(r.p - base);
          mrb_value lazy_new = cbor_lazy_new(mrb, p->buf, value_offset, shareable);
          mrb_hash_set(mrb, kcache, key, lazy_new);
          return lazy_new;
        }

        skip_cbor(mrb, &r, p->buf, shareable);
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

  mrb_value shareable = mrb_hash_new(mrb);

  return cbor_lazy_new(mrb,
                       mrb_str_byte_subseq(mrb, buf, 0, RSTRING_LEN(buf)),
                       0,
                       shareable);
}

MRB_BEGIN_DECL

void
mrb_mruby_cbor_gem_init(mrb_state* mrb)
{
  hex_decode_init();
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