cmake_minimum_required(VERSION 4.3.0)

project(first-rpc
    VERSION 0.1.0
    DESCRIPTION "Cross-platform gRPC client/server for remote ops"
    LANGUAGES CXX
)

set(CMAKE_CXX_STANDARD 23)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)

find_package(Protobuf REQUIRED CONFIG)
find_package(gRPC REQUIRED CONFIG)

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
    COMMAND protobuf::protoc
    ARGS
        --proto_path=${FIRST_RPC_PROTO_DIR}
        --cpp_out=${FIRST_RPC_GENERATED_DIR}
        --grpc_out=${FIRST_RPC_GENERATED_DIR}
        --plugin=protoc-gen-grpc=$<TARGET_FILE:gRPC::grpc_cpp_plugin>
        ${FIRST_RPC_PROTO_FILE}
    DEPENDS ${FIRST_RPC_PROTO_FILE}
    VERBATIM
)

add_library(first_rpc_common
    src/common/system_utils.cpp
    src/common/file_ops.cpp
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

install(TARGETS first_rpc_server first_rpc_client)
