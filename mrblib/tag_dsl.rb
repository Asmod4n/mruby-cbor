module CBOR
  class TagDSL
    attr_reader :encode_type
    attr_reader :encode_proc
    attr_reader :decode_type
    attr_reader :decode_proc

    def initialize
      @encode_type = nil
      @encode_proc = nil
      @decode_type = nil
      @decode_proc = nil
    end

    def encode(type, &block)
      @encode_type = type
      @encode_proc = block
    end

    def decode(type, &block)
      @decode_type = type
      @decode_proc = block
    end
  end

  class << self
    def register_tag(tag, klass = nil, &block)
      if block
        dsl = TagDSL.new
        dsl.instance_eval(&block)

        unless dsl.encode_type && dsl.encode_proc
          raise ArgumentError, "register_tag block must call encode"
        end
        unless dsl.decode_type && dsl.decode_proc
          raise ArgumentError, "register_tag block must call decode"
        end

        register_tag_proc(tag, dsl.encode_type, dsl.encode_proc,
                               dsl.decode_type, dsl.decode_proc)
      else
        register_tag_class(tag, klass)
      end
    end
  end
end
