# -*- cmake -*-

if (CMAKE_SOURCE_DIR STREQUAL CMAKE_CURRENT_SOURCE_DIR)
  cmake_minimum_required(VERSION 3.16.0 FATAL_ERROR)
endif ()

if (NOT CMAKE_HOST_APPLE)
  message(FATAL_ERROR "The Firestorm Metal bootstrap requires a macOS host")
endif ()

set(FIRESTORM_METAL_BOOTSTRAP_IS_STANDALONE OFF)
if (CMAKE_SOURCE_DIR STREQUAL CMAKE_CURRENT_SOURCE_DIR)
  set(FIRESTORM_METAL_BOOTSTRAP_IS_STANDALONE ON)
  set(CMAKE_OSX_ARCHITECTURES "arm64" CACHE STRING
      "Architectures for the standalone Firestorm Metal bootstrap" FORCE)
  set(CMAKE_OSX_DEPLOYMENT_TARGET "13.0" CACHE STRING
      "Minimum macOS version for the standalone Firestorm Metal bootstrap" FORCE)
  project(FirestormMetalBootstrap LANGUAGES CXX OBJCXX)
elseif (NOT CMAKE_OBJCXX_COMPILER_LOADED)
  enable_language(OBJCXX)
endif ()

if (NOT APPLE)
  message(FATAL_ERROR "The Firestorm Metal bootstrap requires macOS")
endif ()

set(FIRESTORM_METAL_BOOTSTRAP_MIN_MACOS "13.0")
set(FIRESTORM_METAL_BOOTSTRAP_METAL_STANDARD "2.3")

find_program(FIRESTORM_XCRUN_EXECUTABLE xcrun)
find_library(FIRESTORM_APPKIT_FRAMEWORK AppKit)
find_library(FIRESTORM_FOUNDATION_FRAMEWORK Foundation)
find_library(FIRESTORM_METAL_FRAMEWORK Metal)
find_library(FIRESTORM_QUARTZCORE_FRAMEWORK QuartzCore)

if (NOT FIRESTORM_XCRUN_EXECUTABLE)
  message(FATAL_ERROR "Could not find xcrun")
endif ()
if (NOT FIRESTORM_APPKIT_FRAMEWORK OR
    NOT FIRESTORM_FOUNDATION_FRAMEWORK OR
    NOT FIRESTORM_METAL_FRAMEWORK OR
    NOT FIRESTORM_QUARTZCORE_FRAMEWORK)
  message(FATAL_ERROR
          "Could not find the AppKit, Foundation, Metal, and QuartzCore frameworks")
endif ()

set(FIRESTORM_METAL_SHADER_SOURCE
    "${CMAKE_CURRENT_SOURCE_DIR}/shaders/bootstrap.metal")
set(FIRESTORM_METAL_GENERATED_DIR
    "${CMAKE_CURRENT_BINARY_DIR}/generated")
set(FIRESTORM_METAL_AIR
    "${FIRESTORM_METAL_GENERATED_DIR}/bootstrap.air")
set(FIRESTORM_METAL_LIBRARY
    "${FIRESTORM_METAL_GENERATED_DIR}/bootstrap.metallib")
if (NOT FIRESTORM_METAL_BOOTSTRAP_IS_STANDALONE)
  # Consumed by the opt-in firestorm-bin integration in sibling directories.
  set(FIRESTORM_METAL_BOOTSTRAP_MIN_MACOS
      "${FIRESTORM_METAL_BOOTSTRAP_MIN_MACOS}" PARENT_SCOPE)
  set(FIRESTORM_METAL_LIBRARY "${FIRESTORM_METAL_LIBRARY}" PARENT_SCOPE)
  set(FIRESTORM_APPKIT_FRAMEWORK "${FIRESTORM_APPKIT_FRAMEWORK}" PARENT_SCOPE)
  set(FIRESTORM_METAL_FRAMEWORK "${FIRESTORM_METAL_FRAMEWORK}" PARENT_SCOPE)
  set(FIRESTORM_QUARTZCORE_FRAMEWORK
      "${FIRESTORM_QUARTZCORE_FRAMEWORK}" PARENT_SCOPE)
endif ()

add_custom_command(
  OUTPUT "${FIRESTORM_METAL_LIBRARY}"
  BYPRODUCTS "${FIRESTORM_METAL_AIR}"
  COMMAND "${CMAKE_COMMAND}" -E make_directory
          "${FIRESTORM_METAL_GENERATED_DIR}"
  COMMAND "${FIRESTORM_XCRUN_EXECUTABLE}" -sdk macosx metal
          "-std=macos-metal${FIRESTORM_METAL_BOOTSTRAP_METAL_STANDARD}"
          "-mmacosx-version-min=${FIRESTORM_METAL_BOOTSTRAP_MIN_MACOS}"
          -c "${FIRESTORM_METAL_SHADER_SOURCE}"
          -o "${FIRESTORM_METAL_AIR}"
  COMMAND "${FIRESTORM_XCRUN_EXECUTABLE}" -sdk macosx metallib
          "${FIRESTORM_METAL_AIR}"
          -o "${FIRESTORM_METAL_LIBRARY}"
  DEPENDS "${FIRESTORM_METAL_SHADER_SOURCE}"
  COMMENT "Compiling the offline Firestorm Metal bootstrap library"
  VERBATIM
  )

add_custom_target(firestorm_metal_bootstrap_shader_library
  DEPENDS "${FIRESTORM_METAL_LIBRARY}"
  )

set_source_files_properties(
  "${FIRESTORM_METAL_LIBRARY}"
  PROPERTIES
    GENERATED TRUE
    MACOSX_PACKAGE_LOCATION Resources
  )

set(FIRESTORM_METAL_BOOTSTRAP_SOURCES
  llmetalbootstrap.h
  llmetalbootstrap-objc.mm
  main-objc.mm
  "${FIRESTORM_METAL_LIBRARY}"
  )

set_source_files_properties(
  llmetalbootstrap-objc.mm
  main-objc.mm
  offscreen-test-objc.mm
  PROPERTIES SKIP_PRECOMPILE_HEADERS TRUE
  )

set(FIRESTORM_METAL_BOOTSTRAP_EXCLUDE_FROM_ALL)
if (NOT FIRESTORM_METAL_BOOTSTRAP_IS_STANDALONE)
  list(APPEND FIRESTORM_METAL_BOOTSTRAP_EXCLUDE_FROM_ALL EXCLUDE_FROM_ALL)
endif ()

add_executable(firestorm_metal_bootstrap MACOSX_BUNDLE
  ${FIRESTORM_METAL_BOOTSTRAP_EXCLUDE_FROM_ALL}
  ${FIRESTORM_METAL_BOOTSTRAP_SOURCES}
  )
add_dependencies(
  firestorm_metal_bootstrap
  firestorm_metal_bootstrap_shader_library
  )

target_compile_features(firestorm_metal_bootstrap PRIVATE cxx_std_20)
target_compile_options(firestorm_metal_bootstrap PRIVATE
  "$<$<COMPILE_LANGUAGE:OBJCXX>:-fobjc-arc>"
  "$<$<COMPILE_LANGUAGE:OBJCXX>:-Wall>"
  "$<$<COMPILE_LANGUAGE:OBJCXX>:-Wextra>"
  "$<$<COMPILE_LANGUAGE:OBJCXX>:-Wpedantic>"
  "$<$<COMPILE_LANGUAGE:OBJCXX>:-mmacosx-version-min=${FIRESTORM_METAL_BOOTSTRAP_MIN_MACOS}>"
  )
target_link_options(firestorm_metal_bootstrap PRIVATE
  "-mmacosx-version-min=${FIRESTORM_METAL_BOOTSTRAP_MIN_MACOS}"
  )
target_link_libraries(firestorm_metal_bootstrap PRIVATE
  "${FIRESTORM_APPKIT_FRAMEWORK}"
  "${FIRESTORM_METAL_FRAMEWORK}"
  "${FIRESTORM_QUARTZCORE_FRAMEWORK}"
  )

add_executable(firestorm_metal_offscreen_test
  ${FIRESTORM_METAL_BOOTSTRAP_EXCLUDE_FROM_ALL}
  offscreen-test-objc.mm
  )
add_dependencies(
  firestorm_metal_offscreen_test
  firestorm_metal_bootstrap_shader_library
  )
target_compile_features(firestorm_metal_offscreen_test PRIVATE cxx_std_20)
target_compile_options(firestorm_metal_offscreen_test PRIVATE
  "$<$<COMPILE_LANGUAGE:OBJCXX>:-fobjc-arc>"
  "$<$<COMPILE_LANGUAGE:OBJCXX>:-Wall>"
  "$<$<COMPILE_LANGUAGE:OBJCXX>:-Wextra>"
  "$<$<COMPILE_LANGUAGE:OBJCXX>:-Wpedantic>"
  "$<$<COMPILE_LANGUAGE:OBJCXX>:-mmacosx-version-min=${FIRESTORM_METAL_BOOTSTRAP_MIN_MACOS}>"
  )
target_link_options(firestorm_metal_offscreen_test PRIVATE
  "-mmacosx-version-min=${FIRESTORM_METAL_BOOTSTRAP_MIN_MACOS}"
  )
target_link_libraries(firestorm_metal_offscreen_test PRIVATE
  "${FIRESTORM_FOUNDATION_FRAMEWORK}"
  "${FIRESTORM_METAL_FRAMEWORK}"
  )
set_target_properties(firestorm_metal_offscreen_test PROPERTIES
  CXX_EXTENSIONS OFF
  CXX_STANDARD 20
  CXX_STANDARD_REQUIRED ON
  OSX_ARCHITECTURES "arm64"
  XCODE_ATTRIBUTE_MACOSX_DEPLOYMENT_TARGET
      "${FIRESTORM_METAL_BOOTSTRAP_MIN_MACOS}"
  )

if (FIRESTORM_METAL_BOOTSTRAP_IS_STANDALONE)
  include(CTest)
  if (BUILD_TESTING)
    add_test(
      NAME firestorm_metal_offscreen_orientation
      COMMAND "${CMAKE_COMMAND}" -E env
              MTL_DEBUG_LAYER=1
              MTL_SHADER_VALIDATION=1
              "$<TARGET_FILE:firestorm_metal_offscreen_test>"
              --metallib "${FIRESTORM_METAL_LIBRARY}"
      )
    set_tests_properties(
      firestorm_metal_offscreen_orientation
      PROPERTIES
        LABELS "metal;gpu"
        TIMEOUT 10
      )
  endif ()
endif ()

set_target_properties(firestorm_metal_bootstrap PROPERTIES
  CXX_EXTENSIONS OFF
  CXX_STANDARD 20
  CXX_STANDARD_REQUIRED ON
  MACOSX_BUNDLE TRUE
  MACOSX_BUNDLE_BUNDLE_NAME "Firestorm Metal Bootstrap"
  MACOSX_BUNDLE_BUNDLE_VERSION "1"
  MACOSX_BUNDLE_COPYRIGHT "Copyright 2026 Firestorm Viewer Project"
  MACOSX_BUNDLE_GUI_IDENTIFIER "org.firestormviewer.metal-bootstrap"
  MACOSX_BUNDLE_INFO_PLIST "${CMAKE_CURRENT_SOURCE_DIR}/Info.plist.in"
  MACOSX_BUNDLE_INFO_STRING "Native Metal presentation bootstrap"
  MACOSX_BUNDLE_LONG_VERSION_STRING "1.0.0"
  MACOSX_BUNDLE_SHORT_VERSION_STRING "1.0.0"
  OUTPUT_NAME "firestorm-metal-bootstrap"
  OSX_ARCHITECTURES "arm64"
  XCODE_ATTRIBUTE_MACOSX_DEPLOYMENT_TARGET
      "${FIRESTORM_METAL_BOOTSTRAP_MIN_MACOS}"
  XCODE_ATTRIBUTE_PRODUCT_BUNDLE_IDENTIFIER
      "org.firestormviewer.metal-bootstrap"
  )

set(FIRESTORM_METAL_CPU_TEST_EXCLUDE_FROM_ALL)
if (NOT FIRESTORM_METAL_BOOTSTRAP_IS_STANDALONE)
  list(APPEND FIRESTORM_METAL_CPU_TEST_EXCLUDE_FROM_ALL EXCLUDE_FROM_ALL)
endif ()

add_executable(firestorm_metal_frame_contracts_test
  ${FIRESTORM_METAL_CPU_TEST_EXCLUDE_FROM_ALL}
  frame-contracts-test.cpp
  llmetalframeslots.cpp
  llmetalframeslots.h
  llmetaltransientarena.cpp
  llmetaltransientarena.h
  )
target_compile_features(firestorm_metal_frame_contracts_test PRIVATE cxx_std_17)
target_compile_options(firestorm_metal_frame_contracts_test PRIVATE
  "$<$<COMPILE_LANGUAGE:CXX>:-Wall>"
  "$<$<COMPILE_LANGUAGE:CXX>:-Wextra>"
  "$<$<COMPILE_LANGUAGE:CXX>:-Wpedantic>"
  )
set_target_properties(firestorm_metal_frame_contracts_test PROPERTIES
  CXX_EXTENSIONS OFF
  CXX_STANDARD 17
  CXX_STANDARD_REQUIRED ON
  )

if (FIRESTORM_METAL_BOOTSTRAP_IS_STANDALONE)
  message(STATUS "Configuring the standalone Firestorm Metal bootstrap")

  include(CTest)
  if (BUILD_TESTING)
    add_test(
      NAME firestorm_metal_frame_contracts
      COMMAND firestorm_metal_frame_contracts_test
      )
  endif ()
endif ()
