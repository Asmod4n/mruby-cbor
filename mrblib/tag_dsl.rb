module CBOR
  class TagDSL
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

    def encode_type; @encode_type; end
    def encode_proc; @encode_proc; end
    def decode_type; @decode_type; end
    def decode_proc; @decode_proc; end
  end

  class << self
    alias_method :register_tag_class, :register_tag

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
