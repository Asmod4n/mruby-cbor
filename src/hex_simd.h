#ifndef HEX_SIMD_H
#define HEX_SIMD_H

#include <stdint.h>
#include <stddef.h>
#include <string.h>

/* ============================================================
 * scalar
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
 * x86 feature detection
 * ============================================================ */

#if defined(__x86_64__) || defined(_M_X64) || defined(__i386__)
#include <cpuid.h>

static inline int cpu_has_sse2(void)
{
    unsigned eax, ebx, ecx, edx;
    if (!__get_cpuid(1, &eax, &ebx, &ecx, &edx)) return 0;
    return (edx & (1u << 26)) != 0;
}

static inline int cpu_has_avx2(void)
{
    unsigned eax, ebx, ecx, edx;
    if (!__get_cpuid_count(7, 0, &eax, &ebx, &ecx, &edx)) return 0;
    return (ebx & (1u << 5)) != 0;
}
#endif

/* ============================================================
 * ARM NEON detection
 * ============================================================ */

#if defined(__aarch64__) || defined(__ARM_NEON)
#include <sys/auxv.h>
#include <asm/hwcap.h>
static inline int cpu_has_neon(void)
{
#ifdef HWCAP_NEON
    return (getauxval(AT_HWCAP) & HWCAP_NEON) != 0;
#else
    return 1;
#endif
}
#endif

/* ============================================================
 * SIMD implementations
 * ============================================================ */

typedef void (*hex_decode_fn)(uint8_t *out, const char *in, size_t len);
static hex_decode_fn hex_decode_impl = hex_decode_scalar;

/* ============================================================
 * x86 SSE2
 * ============================================================ */

#if defined(__x86_64__) || defined(_M_X64) || defined(__i386__)
#include <immintrin.h>

static inline __m128i hex_to_nibble_sse2(__m128i c)
{
    __m128i zero = _mm_set1_epi8('0');
    __m128i nine = _mm_set1_epi8('9');
    __m128i A = _mm_set1_epi8('A');
    __m128i F = _mm_set1_epi8('F');
    __m128i a = _mm_set1_epi8('a');
    __m128i f = _mm_set1_epi8('f');
    __m128i ten = _mm_set1_epi8(10);

    __m128i val0 = _mm_sub_epi8(c, zero);
    __m128i valA = _mm_sub_epi8(c, A);
    __m128i vala = _mm_sub_epi8(c, a);

    __m128i is_digit = _mm_and_si128(_mm_cmpgt_epi8(c, _mm_sub_epi8(zero,_mm_set1_epi8(1))),
                                     _mm_cmplt_epi8(c, _mm_add_epi8(nine,_mm_set1_epi8(1))));
    __m128i is_upper = _mm_and_si128(_mm_cmpgt_epi8(c, _mm_sub_epi8(A,_mm_set1_epi8(1))),
                                     _mm_cmplt_epi8(c, _mm_add_epi8(F,_mm_set1_epi8(1))));
    __m128i is_lower = _mm_and_si128(_mm_cmpgt_epi8(c, _mm_sub_epi8(a,_mm_set1_epi8(1))),
                                     _mm_cmplt_epi8(c, _mm_add_epi8(f,_mm_set1_epi8(1))));

    __m128i val_upper = _mm_add_epi8(valA, ten);
    __m128i val_lower = _mm_add_epi8(vala, ten);

    __m128i res = _mm_and_si128(is_digit, val0);
    res = _mm_or_si128(res, _mm_and_si128(is_upper, val_upper));
    res = _mm_or_si128(res, _mm_and_si128(is_lower, val_lower));
    return res;
}

static inline void hex_decode_sse2(uint8_t *out, const char *in, size_t len)
{
    size_t i = 0;
    for (; i + 32 <= len; i += 32) {
        __m128i c0 = _mm_loadu_si128((const __m128i*)(in + i));
        __m128i c1 = _mm_loadu_si128((const __m128i*)(in + i + 16));

        __m128i n0 = hex_to_nibble_sse2(c0);
        __m128i n1 = hex_to_nibble_sse2(c1);

        uint8_t tmp[32];
        _mm_storeu_si128((__m128i*)(tmp),      n0);
        _mm_storeu_si128((__m128i*)(tmp + 16), n1);

        /* exakt wie scalar: (hi, lo) = (tmp[j], tmp[j+1]) */
        for (int j = 0; j < 32; j += 2) {
            uint8_t hi = tmp[j];
            uint8_t lo = tmp[j+1];
            out[i/2 + j/2] = (uint8_t)((hi << 4) | lo);
        }
    }
    if (i < len) {
        hex_decode_scalar(out + i/2, in + i, len - i);
    }
}


/* ============================================================
 * x86 AVX2
 * ============================================================ */

#if defined(__AVX2__)
static inline __m256i hex_to_nibble_avx2(__m256i c)
{
    __m256i zero = _mm256_set1_epi8('0');
    __m256i nine = _mm256_set1_epi8('9');
    __m256i A = _mm256_set1_epi8('A');
    __m256i F = _mm256_set1_epi8('F');
    __m256i a = _mm256_set1_epi8('a');
    __m256i f = _mm256_set1_epi8('f');
    __m256i ten = _mm256_set1_epi8(10);

    __m256i val0 = _mm256_sub_epi8(c, zero);
    __m256i valA = _mm256_sub_epi8(c, A);
    __m256i vala = _mm256_sub_epi8(c, a);

    __m256i is_digit = _mm256_and_si256(_mm256_cmpgt_epi8(c,_mm256_sub_epi8(zero,_mm256_set1_epi8(1))),
                                        _mm256_cmpgt_epi8(_mm256_add_epi8(nine,_mm256_set1_epi8(1)), c));
    __m256i is_upper = _mm256_and_si256(_mm256_cmpgt_epi8(c,_mm256_sub_epi8(A,_mm256_set1_epi8(1))),
                                        _mm256_cmpgt_epi8(_mm256_add_epi8(F,_mm256_set1_epi8(1)), c));
    __m256i is_lower = _mm256_and_si256(_mm256_cmpgt_epi8(c,_mm256_sub_epi8(a,_mm256_set1_epi8(1))),
                                        _mm256_cmpgt_epi8(_mm256_add_epi8(f,_mm256_set1_epi8(1)), c));

    __m256i val_upper = _mm256_add_epi8(valA, ten);
    __m256i val_lower = _mm256_add_epi8(vala, ten);

    __m256i res = _mm256_and_si256(is_digit, val0);
    res = _mm256_or_si256(res, _mm256_and_si256(is_upper, val_upper));
    res = _mm256_or_si256(res, _mm256_and_si256(is_lower, val_lower));
    return res;
}


static inline void hex_decode_avx2(uint8_t *out, const char *in, size_t len)
{
    size_t i = 0;
    for (; i + 64 <= len; i += 64) {
        __m256i c0 = _mm256_loadu_si256((const __m256i*)(in + i));
        __m256i c1 = _mm256_loadu_si256((const __m256i*)(in + i + 32));

        __m256i n0 = hex_to_nibble_avx2(c0);
        __m256i n1 = hex_to_nibble_avx2(c1);

        uint8_t tmp[64];
        _mm256_storeu_si256((__m256i*)(tmp),      n0);
        _mm256_storeu_si256((__m256i*)(tmp + 32), n1);

        for (int j = 0; j < 64; j += 2) {
            uint8_t hi = tmp[j];
            uint8_t lo = tmp[j+1];
            out[i/2 + j/2] = (uint8_t)((hi << 4) | lo);
        }
    }
    if (i < len) {
        hex_decode_scalar(out + i/2, in + i, len - i);
    }
}


#endif
#endif

/* ============================================================
 * ARM NEON
 * ============================================================ */

#if defined(__ARM_NEON) || defined(__aarch64__)
#include <arm_neon.h>

static inline uint8x16_t hex_to_nibble_neon(uint8x16_t c)
{
    uint8x16_t zero = vdupq_n_u8('0');
    uint8x16_t nine = vdupq_n_u8('9');
    uint8x16_t A = vdupq_n_u8('A');
    uint8x16_t F = vdupq_n_u8('F');
    uint8x16_t a = vdupq_n_u8('a');
    uint8x16_t f = vdupq_n_u8('f');
    uint8x16_t ten = vdupq_n_u8(10);

    uint8x16_t val0 = vsubq_u8(c, zero);
    uint8x16_t valA = vsubq_u8(c, A);
    uint8x16_t vala = vsubq_u8(c, a);

    uint8x16_t is_digit = vandq_u8(vcgeq_u8(c, zero), vcleq_u8(c, nine));
    uint8x16_t is_upper = vandq_u8(vcgeq_u8(c, A), vcleq_u8(c, F));
    uint8x16_t is_lower = vandq_u8(vcgeq_u8(c, a), vcleq_u8(c, f));

    uint8x16_t val_upper = vaddq_u8(valA, ten);
    uint8x16_t val_lower = vaddq_u8(vala, ten);

    uint8x16_t res = vandq_u8(is_digit, val0);
    res = vorrq_u8(res, vandq_u8(is_upper, val_upper));
    res = vorrq_u8(res, vandq_u8(is_lower, val_lower));
    return res;
}

static inline void hex_decode_neon(uint8_t *out, const char *in, size_t len)
{
    size_t i = 0;
    for (; i + 32 <= len; i += 32) {
        uint8x16_t hi_ascii = vld1q_u8((const uint8_t*)(in + i));
        uint8x16_t lo_ascii = vld1q_u8((const uint8_t*)(in + i + 16));

        uint8x16_t hi = hex_to_nibble_neon(hi_ascii);
        uint8x16_t lo = hex_to_nibble_neon(lo_ascii);

        uint8x16_t hi_shift = vshlq_n_u8(hi, 4);
        uint8x16_t bytes = vorrq_u8(hi_shift, lo);

        vst1q_u8(out + i/2, bytes);
    }
    if (i < len) {
        hex_decode_scalar(out + i/2, in + i, len - i);
    }
}
#endif

/* ============================================================
 * dispatch
 * ============================================================ */

static inline void hex_decode_init(void)
{
#if defined(__x86_64__) || defined(_M_X64) || defined(__i386__)
# if defined(__AVX2__)
    if (cpu_has_avx2()) { hex_decode_impl = hex_decode_avx2; return; }
# endif
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

#endif /* HEX_SIMD_H */