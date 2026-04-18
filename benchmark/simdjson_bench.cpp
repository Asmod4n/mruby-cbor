#include <simdjson.h>
#include <chrono>
#include <iostream>
#include <string>
#include <vector>
#include <variant>

using Clock = std::chrono::high_resolution_clock;

static void print_header(const std::string &title) {
  std::cout << std::string(100, '=') << "\n";
  std::cout << title << "\n";
  std::cout << std::string(100, '=') << "\n\n";
}

struct Value {
  std::variant<double, std::string, bool, std::nullptr_t> data;
};

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
    // Materialize all fields (equivalent to mruby .value)
    std::vector<std::pair<std::string, Value>> fields;
    for (auto field : sm) {
      std::string key(field.unescaped_key());
      simdjson::ondemand::value val = field.value();
      Value v;
      switch (val.type()) {
        case simdjson::ondemand::json_type::number:
          v.data = double(val);
          break;
        case simdjson::ondemand::json_type::string:
          v.data = std::string(val.get_string().value());
          break;
        case simdjson::ondemand::json_type::boolean:
          v.data = bool(val);
          break;
        case simdjson::ondemand::json_type::null:
          v.data = nullptr;
          break;
        default:
          break;
      }
      fields.emplace_back(std::move(key), std::move(v));
    }
    auto end = Clock::now();
    double elapsed = std::chrono::duration<double>(end - start).count();
    double ops = 1.0 / elapsed;
    // Print result
    std::cout << "  Result: {";
    bool first = true;
    for (auto &[k, v] : fields) {
      if (!first) std::cout << ", ";
      first = false;
      std::cout << "\"" << k << "\" => ";
      std::visit([](auto &&arg) {
        using T = std::decay_t<decltype(arg)>;
        if constexpr (std::is_same_v<T, double>) std::cout << arg;
        else if constexpr (std::is_same_v<T, std::string>) std::cout << "\"" << arg << "\"";
        else if constexpr (std::is_same_v<T, bool>) std::cout << (arg ? "true" : "false");
        else if constexpr (std::is_same_v<T, std::nullptr_t>) std::cout << "nil";
      }, v.data);
    }
    std::cout << "}\n";
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
    // Materialize all fields
    std::vector<std::pair<std::string, Value>> fields;
    for (auto field : sm) {
      std::string key(field.key);
      Value v;
      switch (field.value.type()) {
        case simdjson::dom::element_type::DOUBLE:
          v.data = double(field.value);
          break;
        case simdjson::dom::element_type::INT64:
          v.data = double(int64_t(field.value));
          break;
        case simdjson::dom::element_type::UINT64:
          v.data = double(uint64_t(field.value));
          break;
        case simdjson::dom::element_type::STRING:
          v.data = std::string(std::string_view(field.value));
          break;
        case simdjson::dom::element_type::BOOL:
          v.data = bool(field.value);
          break;
        case simdjson::dom::element_type::NULL_VALUE:
          v.data = nullptr;
          break;
        default:
          break;
      }
      fields.emplace_back(std::move(key), std::move(v));
    }
    auto end = Clock::now();
    double elapsed = std::chrono::duration<double>(end - start).count();
    double ops = 1.0 / elapsed;
    // Print result
    std::cout << "  Result: {";
    bool first = true;
    for (auto &[k, v] : fields) {
      if (!first) std::cout << ", ";
      first = false;
      std::cout << "\"" << k << "\" => ";
      std::visit([](auto &&arg) {
        using T = std::decay_t<decltype(arg)>;
        if constexpr (std::is_same_v<T, double>) std::cout << arg;
        else if constexpr (std::is_same_v<T, std::string>) std::cout << "\"" << arg << "\"";
        else if constexpr (std::is_same_v<T, bool>) std::cout << (arg ? "true" : "false");
        else if constexpr (std::is_same_v<T, std::nullptr_t>) std::cout << "nil";
      }, v.data);
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
