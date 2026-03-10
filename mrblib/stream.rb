module CBOR
  class << self
    def stream(io, offset = 0)
      return enum_for(:stream, io, offset) unless block_given?

      while true
        io.seek(offset)
        doc = io.read(9)
        break unless doc

        read_size = 9
        len = nil
        while true
          len = size_from(doc, 0)
          break if len

          read_size *= 2
          io.seek(offset)
          doc = io.read(read_size)
          break unless doc
        end
        break unless len

        remaining = len - doc.bytesize
        if remaining > 0
          io.seek(offset + doc.bytesize)
          buf = io.read(remaining)
          break unless buf
          doc << buf
        else
          doc = doc[0, len]
        end

        yield CBOR.decode_lazy(doc)
        offset += len
      end
    end

    private
    def size_from(buf, offset = 0)
      b = buf.getbyte(offset) or return nil
      major = b >> 5
      info  = b & 0x1f
      offset += 1
      arg = 0

      if info < 24
        arg = info
      elsif info == 24
        return nil if offset >= buf.bytesize
        arg = buf.getbyte(offset)
        offset += 1
      elsif info == 25
        return nil if offset + 2 > buf.bytesize
        arg = (buf.getbyte(offset) << 8) | buf.getbyte(offset + 1)
        offset += 2
      elsif info == 26
        return nil if offset + 4 > buf.bytesize
        arg = (buf.getbyte(offset)     << 24) |
              (buf.getbyte(offset + 1) << 16) |
              (buf.getbyte(offset + 2) <<  8) |
              buf.getbyte(offset + 3)
        offset += 4
      elsif info == 27
        return nil if offset + 8 > buf.bytesize
        arg = (buf.getbyte(offset)     << 56) |
              (buf.getbyte(offset + 1) << 48) |
              (buf.getbyte(offset + 2) << 40) |
              (buf.getbyte(offset + 3) << 32) |
              (buf.getbyte(offset + 4) << 24) |
              (buf.getbyte(offset + 5) << 16) |
              (buf.getbyte(offset + 6) <<  8) |
              buf.getbyte(offset + 7)
        offset += 8
      else
        raise TypeError, "payload at offset is not a number"
      end

      case major
      when 0, 1
        offset
      when 2, 3
        return nil if offset + arg > buf.bytesize
        offset + arg
      when 4
        i = 0
        while i < arg
          offset = size_from(buf, offset)
          i += 1
          return nil unless offset
        end
        offset
      when 5
        i = 0
        while i < arg * 2
          offset = size_from(buf, offset)
          i += 1
          return nil unless offset
        end
        offset
      when 6
        size_from(buf, offset)
      when 7
        offset
      end
    end
  end
end
