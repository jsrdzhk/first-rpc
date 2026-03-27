from conan import ConanFile
from conan.tools.cmake import CMake, CMakeDeps, CMakeToolchain, cmake_layout


class FirstRpcConan(ConanFile):
    name = "first-rpc"
    version = "0.1.0"
    package_type = "application"

    settings = "os", "arch", "compiler", "build_type"

    requires = (
        "grpc/1.78.1",
    )

    generators = ()

    def layout(self):
        cmake_layout(self)

    def generate(self):
        deps = CMakeDeps(self)
        deps.generate()

        toolchain = CMakeToolchain(self)
        toolchain.variables["CMAKE_CXX_STANDARD"] = "23"
        toolchain.variables["CMAKE_CXX_STANDARD_REQUIRED"] = "ON"
        toolchain.variables["CMAKE_CXX_EXTENSIONS"] = "OFF"
        toolchain.generate()

    def build(self):
        cmake = CMake(self)
        cmake.configure()
        cmake.build()
