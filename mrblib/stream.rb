module CBOR
  def self.stream(io, offset = 0)
    return enum_for(:stream, io, offset) unless block_given?

    loop do
      # 1) Header lesen (max 9 Bytes)
      io.seek(offset)
      doc = io.read(9)
      break unless doc

      # 2) Lazy auf NUR den Header
      lazy = CBOR.decode_lazy(doc)

      # 3) Gesamtlänge des Dokuments
      len = lazy.end_offset

      # 4) Body nachladen (Header behalten!)
      io.seek(offset + doc.bytesize)
      buf =  io.read(len - doc.bytesize)
      break unless buf
      doc << buf
      # 5) Jetzt hat Lazy das komplette Dokument

      yield CBOR.decode_lazy(doc)

      # 6) Weiter zum nächsten Dokument
      offset += len
    end
  end
end
