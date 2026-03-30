cmake_minimum_required(VERSION 4.3.0)

project(first-rpc
    VERSION 0.1.0
    DESCRIPTION "Cross-platform gRPC client/server for remote ops"
    LANGUAGES CXX
)

include(CTest)

set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)

set(FIRST_RPC_GRPC_ROOT "" CACHE PATH "Path to the locally installed gRPC prefix")

if(NOT FIRST_RPC_GRPC_ROOT)
    message(FATAL_ERROR
        "FIRST_RPC_GRPC_ROOT is not set. Run deps.ps1 or deps.sh first, then "
        "configure with -DFIRST_RPC_GRPC_ROOT=<project>/third_party/grpc-install/<platform-buildtype>."
    )
endif()

if(NOT EXISTS "${FIRST_RPC_GRPC_ROOT}")
    message(FATAL_ERROR "FIRST_RPC_GRPC_ROOT does not exist: ${FIRST_RPC_GRPC_ROOT}")
endif()

list(PREPEND CMAKE_PREFIX_PATH "${FIRST_RPC_GRPC_ROOT}")
list(PREPEND CMAKE_PREFIX_PATH "${FIRST_RPC_GRPC_ROOT}/lib/cmake")
list(PREPEND CMAKE_PREFIX_PATH "${FIRST_RPC_GRPC_ROOT}/lib64/cmake")
list(PREPEND CMAKE_PREFIX_PATH "${FIRST_RPC_GRPC_ROOT}/cmake")
list(PREPEND CMAKE_PROGRAM_PATH "${FIRST_RPC_GRPC_ROOT}/bin")

find_package(Protobuf REQUIRED CONFIG)
find_package(gRPC REQUIRED CONFIG)

find_program(FIRST_RPC_PROTOC_EXECUTABLE
    NAMES protoc
    HINTS "${FIRST_RPC_GRPC_ROOT}/bin"
    REQUIRED
)

find_program(FIRST_RPC_GRPC_CPP_PLUGIN
    NAMES grpc_cpp_plugin
    HINTS "${FIRST_RPC_GRPC_ROOT}/bin"
    REQUIRED
)

set(FIRST_RPC_PROTO_DIR ${PROJECT_SOURCE_DIR}/proto)
set(FIRST_RPC_PROTO_FILE ${FIRST_RPC_PROTO_DIR}/first_rpc.proto)
set(FIRST_RPC_GENERATED_DIR ${CMAKE_CURRENT_BINARY_DIR}/generated)

file(MAKE_DIRECTORY ${FIRST_RPC_GENERATED_DIR})

set(FIRST_RPC_PROTO_SRCS
    ${FIRST_RPC_GENERATED_DIR}/first_rpc.pb.cc
    ${FIRST_RPC_GENERATED_DIR}/first_rpc.grpc.pb.cc
)

set(FIRST_RPC_PROTO_HDRS
    ${FIRST_RPC_GENERATED_DIR}/first_rpc.pb.h
    ${FIRST_RPC_GENERATED_DIR}/first_rpc.grpc.pb.h
)

add_custom_command(
    OUTPUT ${FIRST_RPC_PROTO_SRCS} ${FIRST_RPC_PROTO_HDRS}
    COMMAND ${FIRST_RPC_PROTOC_EXECUTABLE}
    ARGS
        --proto_path=${FIRST_RPC_PROTO_DIR}
        --cpp_out=${FIRST_RPC_GENERATED_DIR}
        --grpc_out=${FIRST_RPC_GENERATED_DIR}
        --plugin=protoc-gen-grpc=${FIRST_RPC_GRPC_CPP_PLUGIN}
        ${FIRST_RPC_PROTO_FILE}
    DEPENDS ${FIRST_RPC_PROTO_FILE}
    VERBATIM
)

add_library(first_rpc_common
    src/common/system_utils.cpp
    src/common/file_ops.cpp
    src/common/exec_utils.cpp
    src/common/format.cpp
    ${FIRST_RPC_PROTO_SRCS}
)

target_include_directories(first_rpc_common
    PUBLIC
        ${PROJECT_SOURCE_DIR}/include
        ${FIRST_RPC_GENERATED_DIR}
)

target_link_libraries(first_rpc_common
    PUBLIC
        protobuf::libprotobuf
        gRPC::grpc++
)

if(WIN32)
    target_link_libraries(first_rpc_common PUBLIC ws2_32)
endif()

add_executable(first_rpc_server
    src/server/main.cpp
    src/server/service_impl.cpp
)

target_link_libraries(first_rpc_server PRIVATE first_rpc_common)

add_executable(first_rpc_client
    src/client/main.cpp
    src/client/rpc_client.cpp
)

target_link_libraries(first_rpc_client PRIVATE first_rpc_common)

if(BUILD_TESTING)
    include(FetchContent)

    FetchContent_Declare(
        Catch2
        GIT_REPOSITORY https://github.com/catchorg/Catch2.git
        GIT_TAG v3.7.1
    )

    FetchContent_MakeAvailable(Catch2)

    add_executable(first_rpc_tests
        tests/cpp/file_ops_tests.cpp
        tests/cpp/format_tests.cpp
        tests/cpp/upload_service_tests.cpp
        tests/cpp/exec_service_tests.cpp
        src/server/service_impl.cpp
    )

    target_link_libraries(first_rpc_tests
        PRIVATE
            first_rpc_common
            Catch2::Catch2WithMain
    )

    target_include_directories(first_rpc_tests
        PRIVATE
            ${PROJECT_SOURCE_DIR}/include
            ${FIRST_RPC_GENERATED_DIR}
    )

    include(Catch)
    catch_discover_tests(first_rpc_tests)
endif()

install(TARGETS first_rpc_server first_rpc_client)
