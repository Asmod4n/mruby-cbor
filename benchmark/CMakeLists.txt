cmake_minimum_required(VERSION 3.14)
project(simdjson_bench CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

include(FetchContent)
FetchContent_Declare(
  simdjson
  URL https://github.com/simdjson/simdjson/releases/download/v4.6.1/singleheader.zip
)
FetchContent_MakeAvailable(simdjson)

add_library(simdjson_lib STATIC ${simdjson_SOURCE_DIR}/simdjson.cpp)
target_include_directories(simdjson_lib PUBLIC ${simdjson_SOURCE_DIR})
target_compile_options(simdjson_lib PRIVATE -O3 -march=native)

add_executable(simdjson_bench simdjson_bench.cpp)
target_link_libraries(simdjson_bench PRIVATE simdjson_lib)
target_compile_options(simdjson_bench PRIVATE -O3 -march=native)
