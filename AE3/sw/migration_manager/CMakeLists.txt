cmake_minimum_required(VERSION 3.16)

project(migration_manager C CXX)

set(CMAKE_CXX_STANDARD 11)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS ON)

if(NOT CMAKE_BUILD_TYPE)
  set(CMAKE_BUILD_TYPE Release CACHE STRING "Build type" FORCE)
endif()
set(CMAKE_CXX_FLAGS_RELEASE "-O2" CACHE STRING "Release C++ flags" FORCE)

set(AE_BAR_PATH "" CACHE STRING "Absolute sysfs resource2 path")
set(AE_CXL_MEM_START "" CACHE STRING "CXL memory start address")
set(AE_CXL_MEM_PFN "" CACHE STRING "First CXL page-frame number")
set(AE_CXL_MEM_NUM_PFN "" CACHE STRING "Number of 4 KiB CXL pages")
set(AE_CXL_NODE "" CACHE STRING "CXL NUMA node")
set(AE_MIGRATION_TARGET_NODE "" CACHE STRING "DRAM migration target NUMA node")

foreach(required_value
    AE_BAR_PATH
    AE_CXL_MEM_START
    AE_CXL_MEM_PFN
    AE_CXL_MEM_NUM_PFN
    AE_CXL_NODE
    AE_MIGRATION_TARGET_NODE)
  if("${${required_value}}" STREQUAL "")
    message(FATAL_ERROR "${required_value} is required; run set_default/setup_default.sh build")
  endif()
endforeach()

add_executable(${PROJECT_NAME}
    src/util.cpp
    src/csr.cpp
    src/worker.cpp
    src/main.cpp
)
target_include_directories(${PROJECT_NAME}
    PRIVATE
    ${PROJECT_SOURCE_DIR}/include
)
target_compile_options(${PROJECT_NAME} PRIVATE -Wall -Wextra -march=native -g)
target_compile_definitions(${PROJECT_NAME} PRIVATE
    CXL_PCIE_BAR_PATH="${AE_BAR_PATH}"
    CXL_NODE_START_ADDR=${AE_CXL_MEM_START}
    CXL_MEM_PFN_BEGIN=${AE_CXL_MEM_PFN}
    CXL_MEM_NUM_PFN=${AE_CXL_MEM_NUM_PFN}
    CXL_NODE=${AE_CXL_NODE}
    MIGRATION_TARGET_NODE=${AE_MIGRATION_TARGET_NODE}
)

target_link_libraries(${PROJECT_NAME} numa pthread)
