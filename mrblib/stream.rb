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
  end
end
