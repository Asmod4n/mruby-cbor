module CBOR
  class StreamDecoder
    def initialize(&block)
      @buf   = ""
      @block = block
    end

    def feed(chunk)
      @buf << chunk
      while true
        len = CBOR.doc_end(@buf, 0)
        break unless len
        @block.call(CBOR.decode_lazy(@buf.byteslice(0, len)))
        @buf = @buf.byteslice(len, @buf.bytesize - len)
      end
    end
  end

  class << self
    def stream(io, offset = 0, &block)
      if io.respond_to?(:bytesize) && io.respond_to?(:byteslice)
        stream_string(io, offset, &block)
      elsif io.respond_to?(:recv)
        stream_socket(io, &block)
      elsif io.respond_to?(:seek) && io.respond_to?(:read)
        stream_file(io, offset, &block)
      else
        raise TypeError, "expected String, File or IO"
      end
    end

    def stream_string(str, offset = 0, &block)
      return enum_for(:stream_string, str, offset) unless block
      while offset < str.bytesize
        len = doc_end(str, offset)
        break unless len
        yield CBOR.decode_lazy(str.byteslice(offset, len - offset))
        offset = len
      end
    end

    def stream_file(io, offset = 0, &block)
      return enum_for(:stream_file, io, offset) unless block
      while true
        io.seek(offset)
        doc = io.read(9)
        break unless doc
        read_size = 9
        len = nil
        while true
          len = doc_end(doc, 0)
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

    def stream_socket(io, &block)
      return StreamDecoder.new(&block) unless block
      buf = ""
      while chunk = io.read(4095)
        buf << chunk
        while true
          len = doc_end(buf, 0)
          break unless len
          yield CBOR.decode_lazy(buf.byteslice(0, len))
          buf = buf.byteslice(len, buf.bytesize - len)
        end
      end
    end

    def doc_end(buf, offset = 0)
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
          offset = doc_end(buf, offset)
          i += 1
          return nil unless offset
        end
        offset
      when 5
        i = 0
        while i < arg * 2
          offset = doc_end(buf, offset)
          i += 1
          return nil unless offset
        end
        offset
      when 6
        doc_end(buf, offset)
      when 7
        offset
      end
    end
  end
end
