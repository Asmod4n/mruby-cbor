module CBOR
  # CBOR.diagnose(buf) → String
  #
  # Returns RFC 8949 §8.1 diagnostic notation for the CBOR value in +buf+.
  #
  #   CBOR.diagnose("\xf9\x3c\x00")              #=> "1.0_1"
  #   CBOR.diagnose("\x82\x01\x82\x02\x03")      #=> "[1, [2, 3]]"
  #   CBOR.diagnose("\xa1\x61a\x01")             #=> '{"a": 1}'
  #   CBOR.diagnose("\xf9\x7e\x00")              #=> "NaN_1"
  #   CBOR.diagnose("\xc1\x1a\x51\x4b\x67\xb0") #=> "1(1363896240)"
  #
  # Float width suffix: _1=f16, _2=f32, _3=f64 (RFC 8610 §8.1 convention).
  # Works on all mruby builds including MRB_NO_FLOAT; when Float is absent
  # f16/f32 use exact rational arithmetic and f64 uses hex-float notation.
  #
  module Diagnose
    HEX_CHARS = "0123456789abcdef"

    HAVE_FLOAT = Object.const_defined?(:Float)

    # ── Hex helpers ────────────────────────────────────────────────────────

    def self.nibble(n)
      HEX_CHARS[n & 0xF, 1]
    end

    def self.byte_hex(b)
      nibble(b >> 4) + nibble(b)
    end

    # Integer → hex string, no Integer#to_s(base) needed
    def self.int_hex(n)
      return "0" if n == 0
      s = ""
      while n > 0
        s = nibble(n) + s
        n = n >> 4
      end
      s
    end

    # ── CBOR uint reader ───────────────────────────────────────────────────

    # Returns [value, new_pos].  value is always an Integer (possibly large).
    def self.read_uint(buf, pos, info)
      if info < 24
        [info, pos]
      elsif info == 24
        [buf.getbyte(pos), pos + 1]
      elsif info == 25
        v = (buf.getbyte(pos) << 8) | buf.getbyte(pos + 1)
        [v, pos + 2]
      elsif info == 26
        # Avoid << 24 which overflows mrb_int on MRB_INT32 builds.
        hi16 = (buf.getbyte(pos)     << 8) | buf.getbyte(pos + 1)
        lo16 = (buf.getbyte(pos + 2) << 8) | buf.getbyte(pos + 3)
        [hi16 * 65536 + lo16, pos + 4]
      elsif info == 27
        hi = (buf.getbyte(pos)     << 24) |
             (buf.getbyte(pos + 1) << 16) |
             (buf.getbyte(pos + 2) <<  8) |
              buf.getbyte(pos + 3)
        lo = (buf.getbyte(pos + 4) << 24) |
             (buf.getbyte(pos + 5) << 16) |
             (buf.getbyte(pos + 6) <<  8) |
              buf.getbyte(pos + 7)
        # Multiply to avoid overflow on 32-bit mrb_int builds
        [hi * 4294967296 + lo, pos + 8]
      elsif info == 31
        [:indef, pos]
      else
        raise RuntimeError, "reserved additional info #{info}"
      end
    end

    # ── String formatters ──────────────────────────────────────────────────

    def self.fmt_bytes(buf, pos, len)
      s = "h'"
      i = 0
      while i < len
        s = s + byte_hex(buf.getbyte(pos + i))
        i = i + 1
      end
      s + "'"
    end

    def self.fmt_text(buf, pos, len)
      s = '"'
      i = 0
      while i < len
        b = buf.getbyte(pos + i)
        if b == 34        # "
          s = s + '\\"'
          i = i + 1
        elsif b == 92     # \
          s = s + '\\\\'
          i = i + 1
        elsif b < 0x20
          s = s + "\\u00" + byte_hex(b)
          i = i + 1
        elsif b < 0x80
          # Plain ASCII: emit directly.  Single-byte chars are safe to index.
          s = s + buf[pos + i, 1]
          i = i + 1
        else
          # Multi-byte UTF-8 sequence.  Decode the codepoint purely from bytes
          # (no character indexing) and emit as a \uXXXX escape.  This avoids
          # the mruby String#[] character-vs-byte ambiguity for non-ASCII text.
          # CBOR guarantees valid UTF-8 so continuation bytes are always present.
          if b < 0xE0
            cp = ((b & 0x1F) << 6) | (buf.getbyte(pos + i + 1) & 0x3F)
            i = i + 2
          elsif b < 0xF0
            cp = ((b & 0x0F) << 12) |
                 ((buf.getbyte(pos + i + 1) & 0x3F) << 6) |
                  (buf.getbyte(pos + i + 2) & 0x3F)
            i = i + 3
          else
            cp = ((b & 0x07) << 18) |
                 ((buf.getbyte(pos + i + 1) & 0x3F) << 12) |
                 ((buf.getbyte(pos + i + 2) & 0x3F) << 6) |
                  (buf.getbyte(pos + i + 3) & 0x3F)
            i = i + 4
          end
          # Emit as \uXXXX (BMP) or surrogate pair (supplementary, JSON §7 style)
          if cp <= 0xFFFF
            s = s + "\\u" + byte_hex(cp >> 8) + byte_hex(cp & 0xFF)
          else
            cp2 = cp - 0x10000
            hi  = 0xD800 | (cp2 >> 10)
            lo  = 0xDC00 | (cp2 & 0x3FF)
            s = s + "\\u" + byte_hex(hi >> 8) + byte_hex(hi & 0xFF) +
                    "\\u" + byte_hex(lo >> 8) + byte_hex(lo & 0xFF)
          end
        end
      end
      s + '"'
    end

    # ── Float formatters ───────────────────────────────────────────────────
    #
    # When Float is available we reconstruct the value and use inspect.
    # When Float is absent we use exact rational arithmetic for f16/f32
    # and hex-float notation for f64 (valid per RFC 8610 App. G).

    # Render num * 2^(-shift) as a minimal decimal string.
    # shift > 0  → fractional;  shift <= 0 → integer * 2^|shift|
    def self.rational_decimal(sign_str, num, shift)
      if shift <= 0
        v = num
        (-shift).times { v = v * 2 }
        return sign_str + v.to_s + ".0"
      end
      # value = num * 5^shift / 10^shift
      pow5 = 1
      shift.times { pow5 = pow5 * 5 }
      digits = (num * pow5).to_s
      while digits.length <= shift
        digits = "0" + digits
      end
      int_part  = digits[0, digits.length - shift]
      frac_part = digits[digits.length - shift, shift]
      # strip trailing zeros, keep at least one fractional digit
      i = frac_part.length - 1
      while i > 0 && frac_part[i, 1] == "0"
        i = i - 1
      end
      sign_str + int_part + "." + frac_part[0, i + 1]
    end

    def self.fmt_f16(h)
      sign  = (h >> 15) & 1
      exp16 = (h >> 10) & 0x1F
      mant  = h & 0x3FF
      pfx   = sign == 1 ? "-" : ""

      if exp16 == 0x1F
        return mant != 0 ? "NaN_1" : pfx + "Infinity_1"
      end
      if exp16 == 0 && mant == 0
        return pfx + "0.0_1"
      end

      if HAVE_FLOAT
        # For f16 normals, reconstruct via f32 and use Float#inspect.
        # Subnormals always use rational arithmetic (exact, and inspect
        # may not emit enough digits for tiny values like 2^-24).
        if exp16 != 0
          u32 = (sign << 31) | ((exp16 + 112) << 23) | (mant << 13)
          return float_fmt_u32(u32) + "_1"
        end
      end

      if exp16 == 0
        # subnormal: mant * 2^-24
        rational_decimal(pfx, mant, 24) + "_1"
      else
        # normal: (1024 + mant) * 2^(exp16-25)
        rational_decimal(pfx, 1024 + mant, 25 - exp16) + "_1"
      end
    end

    def self.fmt_f32(u32)
      sign  = (u32 >> 31) & 1
      exp32 = (u32 >> 23) & 0xFF
      mant  = u32 & 0x7FFFFF
      pfx   = sign == 1 ? "-" : ""

      if exp32 == 0xFF
        return mant != 0 ? "NaN_2" : pfx + "Infinity_2"
      end
      if exp32 == 0 && mant == 0
        return pfx + "0.0_2"
      end

      if HAVE_FLOAT && exp32 != 0
        return float_fmt_u32(u32) + "_2"
      end

      if exp32 == 0
        rational_decimal(pfx, mant, 149) + "_2"       # mant * 2^-149
      else
        rational_decimal(pfx, 8388608 + mant, 150 - exp32) + "_2"
      end
    end

    def self.fmt_f64(hi, lo)
      sign   = (hi >> 31) & 1
      exp64  = (hi >> 20) & 0x7FF
      mhi    = hi & 0xFFFFF
      pfx    = sign == 1 ? "-" : ""

      if exp64 == 0x7FF
        return (mhi != 0 || lo != 0) ? "NaN_3" : pfx + "Infinity_3"
      end
      if exp64 == 0 && mhi == 0 && lo == 0
        return pfx + "0.0_3"
      end

      if HAVE_FLOAT
        return float_fmt_u64(hi, lo) + "_3"
      end

      # No Float: emit hex-float notation (RFC 8610 §G)
      mant52 = mhi * 4294967296 + lo
      mhex   = int_hex(mant52)
      mhex   = "0" * (13 - mhex.length) + mhex if mhex.length < 13
      exp_v  = exp64 == 0 ? -1022 : exp64 - 1023
      impl   = exp64 == 0 ? "0" : "1"
      pfx + "0x" + impl + "." + mhex + "p" + exp_v.to_s + "_3"
    end

    if HAVE_FLOAT
      def self.float_fmt_u32(u32)
        sign  = (u32 >> 31) & 1
        exp32 = (u32 >> 23) & 0xFF
        mant  = u32 & 0x7FFFFF
        f = if exp32 == 0
          mant.to_f * (2.0 ** -149)
        else
          (8388608.0 + mant.to_f) * (2.0 ** (exp32 - 150))
        end
        f = -f if sign == 1
        s = f.inspect
        s.include?(".") ? s : s + ".0"
      end

      def self.float_fmt_u64(hi, lo)
        sign  = (hi >> 31) & 1
        exp64 = (hi >> 20) & 0x7FF
        mhi   = hi & 0xFFFFF
        mant52 = mhi * 4294967296 + lo
        f = if exp64 == 0
          mant52.to_f * (2.0 ** -1074)
        else
          (1.0 + mant52.to_f * (2.0 ** -52)) * (2.0 ** (exp64 - 1023))
        end
        f = -f if sign == 1
        s = f.inspect
        s.include?(".") ? s : s + ".0"
      end
    end

    # ── Core recursive decoder ─────────────────────────────────────────────

    # Returns [diag_string, new_pos]
    def self.diag(buf, pos)
      b     = buf.getbyte(pos)
      major = b >> 5
      info  = b & 0x1F
      pos   = pos + 1

      case major
      when 0  # unsigned integer
        n, pos = read_uint(buf, pos, info)
        [n.to_s, pos]

      when 1  # negative integer
        n, pos = read_uint(buf, pos, info)
        [(-1 - n).to_s, pos]

      when 2  # byte string
        if info == 31
          parts = []
          while buf.getbyte(pos) != 0xFF
            ii = buf.getbyte(pos) & 0x1F
            pos = pos + 1
            len, pos = read_uint(buf, pos, ii)
            parts.push(fmt_bytes(buf, pos, len))
            pos = pos + len
          end
          ["(_ " + parts.join(",") + ")", pos + 1]
        else
          len, pos = read_uint(buf, pos, info)
          [fmt_bytes(buf, pos, len), pos + len]
        end

      when 3  # text string
        if info == 31
          parts = []
          while buf.getbyte(pos) != 0xFF
            ii = buf.getbyte(pos) & 0x1F
            pos = pos + 1
            len, pos = read_uint(buf, pos, ii)
            parts.push(fmt_text(buf, pos, len))
            pos = pos + len
          end
          ["(_ " + parts.join(",") + ")", pos + 1]
        else
          len, pos = read_uint(buf, pos, info)
          [fmt_text(buf, pos, len), pos + len]
        end

      when 4  # array
        if info == 31
          items = []
          while buf.getbyte(pos) != 0xFF
            s, pos = diag(buf, pos)
            items.push(s)
          end
          ["[_ " + items.join(",") + "]", pos + 1]
        else
          count, pos = read_uint(buf, pos, info)
          items = []
          i = 0
          while i < count
            s, pos = diag(buf, pos)
            items.push(s)
            i = i + 1
          end
          ["[" + items.join(",") + "]", pos]
        end

      when 5  # map
        if info == 31
          pairs = []
          while buf.getbyte(pos) != 0xFF
            ks, pos = diag(buf, pos)
            vs, pos = diag(buf, pos)
            pairs.push(ks + ":" + vs)
          end
          ["{_ " + pairs.join(",") + "}", pos + 1]
        else
          count, pos = read_uint(buf, pos, info)
          pairs = []
          i = 0
          while i < count
            ks, pos = diag(buf, pos)
            vs, pos = diag(buf, pos)
            pairs.push(ks + ":" + vs)
            i = i + 1
          end
          ["{" + pairs.join(",") + "}", pos]
        end

      when 6  # tag
        tag, pos = read_uint(buf, pos, info)
        val, pos = diag(buf, pos)
        [tag.to_s + "(" + val + ")", pos]

      when 7  # float / simple
        case info
        when 20 then ["false",     pos]
        when 21 then ["true",      pos]
        when 22 then ["null",      pos]
        when 23 then ["undefined", pos]
        when 24
          sv = buf.getbyte(pos)
          ["simple(" + sv.to_s + ")", pos + 1]
        when 25
          h = (buf.getbyte(pos) << 8) | buf.getbyte(pos + 1)
          [fmt_f16(h), pos + 2]
        when 26
          u32 = (buf.getbyte(pos)     << 24) |
                (buf.getbyte(pos + 1) << 16) |
                (buf.getbyte(pos + 2) <<  8) |
                 buf.getbyte(pos + 3)
          [fmt_f32(u32), pos + 4]
        when 27
          hi = (buf.getbyte(pos)     << 24) |
               (buf.getbyte(pos + 1) << 16) |
               (buf.getbyte(pos + 2) <<  8) |
                buf.getbyte(pos + 3)
          lo = (buf.getbyte(pos + 4) << 24) |
               (buf.getbyte(pos + 5) << 16) |
               (buf.getbyte(pos + 6) <<  8) |
                buf.getbyte(pos + 7)
          [fmt_f64(hi, lo), pos + 8]
        when 31
          ["break", pos]
        else
          ["simple(" + info.to_s + ")", pos]
        end

      else
        raise RuntimeError, "unknown major type #{major}"
      end
    end
  end

  class << self
    def diagnose(buf)
      s, _pos = Diagnose.diag(buf, 0)
      s
    end
  end
end
