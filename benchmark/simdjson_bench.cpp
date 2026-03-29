#include <simdjson.h>
#include <chrono>
#include <iostream>
#include <string>

using Clock = std::chrono::high_resolution_clock;

static void print_header(const std::string &title) {
  std::cout << std::string(100, '=') << "\n";
  std::cout << title << "\n";
  std::cout << std::string(100, '=') << "\n\n";
}

static void print_object(simdjson::ondemand::object obj) {
  std::cout << "{";
  bool first = true;
  for (auto field : obj) {
    if (!first) std::cout << ", ";
    first = false;

    std::string_view key = field.unescaped_key();
    simdjson::ondemand::value val = field.value();

    std::cout << "\"" << key << "\" => ";

    // Print values similar to Ruby's inspect
    switch (val.type()) {
      case simdjson::ondemand::json_type::number:
        std::cout << double(val);
        break;
      case simdjson::ondemand::json_type::string:
        std::cout << "\"" << std::string(val.get_string().value()) << "\"";
        break;
      case simdjson::ondemand::json_type::boolean:
        std::cout << (bool(val) ? "true" : "false");
        break;
      case simdjson::ondemand::json_type::null:
        std::cout << "nil";
        break;
      default:
        std::cout << "<complex>";
    }
  }
  std::cout << "}";
}

int main(int argc, char **argv) {
  const char *filename = "twitter.json";
  if (argc > 1) filename = argv[1];

  simdjson::ondemand::parser ondemand_parser;
  simdjson::dom::parser dom_parser;

  // Load file
  simdjson::padded_string json = simdjson::padded_string::load(filename);

  std::cout << "File: " << filename << " (" << json.size() << " bytes)\n\n";

  // EAGER DECODE
  print_header("EAGER DECODE BENCHMARK (twitter.json)");

  {
    std::cout << "simdjson DOM parse\n";
    auto start = Clock::now();

    simdjson::dom::element doc;
    dom_parser.parse(json).get(doc);

    auto end = Clock::now();
    double elapsed = std::chrono::duration<double>(end - start).count();
    double ops = 1.0 / elapsed;

    std::cout << "  Time: " << elapsed << " sec\n";
    std::cout << "  OPS:  " << ops << "\n\n";
  }

  // LAZY DECODE
  print_header("LAZY DECODE BENCHMARK — /search_metadata");

  {
    std::cout << "simdjson On-Demand\n";
    auto start = Clock::now();

    simdjson::ondemand::document doc = ondemand_parser.iterate(json);
    simdjson::ondemand::object root = doc.get_object();
    simdjson::ondemand::object sm = root["search_metadata"];

    auto end = Clock::now();
    double elapsed = std::chrono::duration<double>(end - start).count();
    double ops = 1.0 / elapsed;

    std::cout << "  Result: ";
    print_object(sm);
    std::cout << "\n";

    std::cout << "  Time: " << elapsed << " sec\n";
    std::cout << "  OPS:  " << ops << "\n\n";
  }

  {
    std::cout << "simdjson DOM (parse + /search_metadata)\n";
    auto start = Clock::now();

    simdjson::dom::element doc;
    dom_parser.parse(json).get(doc);

    simdjson::dom::object root = doc.get_object();
    simdjson::dom::object sm = root["search_metadata"];

    auto end = Clock::now();
    double elapsed = std::chrono::duration<double>(end - start).count();
    double ops = 1.0 / elapsed;

    std::cout << "  Result: {";
    bool first = true;
    for (auto field : sm) {
      if (!first) std::cout << ", ";
      first = false;
      std::cout << "\"" << std::string(field.key) << "\" => " << field.value;
    }
    std::cout << "}\n";

    std::cout << "  Time: " << elapsed << " sec\n";
    std::cout << "  OPS:  " << ops << "\n\n";
  }

  std::cout << std::string(100, '=') << "\n";
  std::cout << "Done.\n";
  std::cout << std::string(100, '=') << "\n";

  return 0;
}
