$data = File.read('twitter.json')
$cbor = CBOR.encode(JSON.parse($data))
$dom_parser = JSON::DomParser.new
$dom_parser.allocate(File.size('twitter.json'))
$ondemand_parser = JSON::OndemandParser.new
$ondemand_parser.allocate(File.size('twitter.json'))
$msgpack = MessagePack.pack(JSON.parse($data))
Benchmark.bm do |run|


  run.report('lazy') do
          lazy = CBOR.decode_lazy($cbor)

    250000.times do

      lazy["statuses"][50].value
    end
  end



  run.report('json lazy') do
                lazy = JSON.parse_lazy($data)

    250000.times do

      lazy["statuses"][50]
    end
  end



end
