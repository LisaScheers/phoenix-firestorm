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
option(FIRESTORM_BUILD_METAL_PROGRAM_ARTIFACTS
       "Build the representative declared Metal program artifact and focused test"
       OFF)
set(FIRESTORM_METAL_OPENGL_ORACLE_WORKTREE "" CACHE PATH
    "Pinned detached Firestorm worktree used only by the opt-in OpenGL semantic oracle")
if (FIRESTORM_BUILD_ACTIVE_METAL_VIEWER)
  # A normal variable makes the implication local to this configure. It does
  # not leave the independent artifact option enabled in the cache later.
  set(FIRESTORM_BUILD_METAL_PROGRAM_ARTIFACTS ON)
endif ()

# Nix's SDK compatibility shim is also named xcrun, but it cannot discover
# Xcode's separately installed Metal toolchain. The system launcher respects
# DEVELOPER_DIR and Apple's MobileAsset Metal toolchain installation.
find_program(FIRESTORM_XCRUN_EXECUTABLE xcrun
  PATHS /usr/bin
  NO_DEFAULT_PATH
  )
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
  llmetalframecontext.h
  llmetalframecontext-objc.mm
  llmetalframeslots.cpp
  llmetalframeslots.h
  llmetaltransientarena.cpp
  llmetaltransientarena.h
  main-objc.mm
  "${FIRESTORM_METAL_LIBRARY}"
  )

set_source_files_properties(
  artifact-vertex-index-test-objc.mm
  blend-pipeline-test-objc.mm
  color-gamma-test-objc.mm
  depth-raster-test-objc.mm
  frame-context-test-objc.mm
  llmetalbootstrap-objc.mm
  llmetalframecontext-objc.mm
  llmetalgeometry-objc.mm
  llmetalpipeline-objc.mm
  llmetalprogram-objc.mm
  llmetalrenderpass-objc.mm
  llmetalresource-objc.mm
  llmetalsampler-objc.mm
  llmetalstate-objc.mm
  llmetaltransfer-objc.mm
  main-objc.mm
  mrt-test-objc.mm
  offscreen-test-objc.mm
  program-library-test-objc.mm
  render-pass-test-objc.mm
  resource-transfer-test-objc.mm
  sampler-test-objc.mm
  texture-subresources-test-objc.mm
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
  XCODE_ATTRIBUTE_CLANG_ENABLE_OBJC_ARC YES
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

add_executable(firestorm_metal_resource_layout_test
  ${FIRESTORM_METAL_CPU_TEST_EXCLUDE_FROM_ALL}
  llmetalformat.cpp
  llmetalformat.h
  resource-layout-test.cpp
  )
target_compile_features(firestorm_metal_resource_layout_test PRIVATE cxx_std_17)
target_compile_options(firestorm_metal_resource_layout_test PRIVATE
  "$<$<COMPILE_LANGUAGE:CXX>:-Wall>"
  "$<$<COMPILE_LANGUAGE:CXX>:-Wextra>"
  "$<$<COMPILE_LANGUAGE:CXX>:-Wpedantic>"
  "$<$<COMPILE_LANGUAGE:CXX>:-Werror>"
  "$<$<COMPILE_LANGUAGE:CXX>:-Wconversion>"
  "$<$<COMPILE_LANGUAGE:CXX>:-Wsign-conversion>"
  )
set_target_properties(firestorm_metal_resource_layout_test PROPERTIES
  CXX_EXTENSIONS OFF
  CXX_STANDARD 17
  CXX_STANDARD_REQUIRED ON
  )

add_executable(firestorm_metal_frame_context_test
  ${FIRESTORM_METAL_CPU_TEST_EXCLUDE_FROM_ALL}
  frame-context-test-objc.mm
  llmetalframecontext-objc.mm
  llmetalframecontext.h
  llmetalframeslots.cpp
  llmetalframeslots.h
  llmetaltransientarena.cpp
  llmetaltransientarena.h
  )
target_compile_features(firestorm_metal_frame_context_test PRIVATE cxx_std_17)
target_compile_options(firestorm_metal_frame_context_test PRIVATE
  "$<$<COMPILE_LANGUAGE:CXX,OBJCXX>:-Wall>"
  "$<$<COMPILE_LANGUAGE:CXX,OBJCXX>:-Wextra>"
  "$<$<COMPILE_LANGUAGE:CXX,OBJCXX>:-Wpedantic>"
  "$<$<COMPILE_LANGUAGE:CXX,OBJCXX>:-Werror>"
  "$<$<COMPILE_LANGUAGE:CXX,OBJCXX>:-Wconversion>"
  "$<$<COMPILE_LANGUAGE:CXX,OBJCXX>:-Wsign-conversion>"
  "$<$<COMPILE_LANGUAGE:OBJCXX>:-fobjc-arc>"
  "$<$<COMPILE_LANGUAGE:OBJCXX>:-mmacosx-version-min=${FIRESTORM_METAL_BOOTSTRAP_MIN_MACOS}>"
  )
if (NOT FIRESTORM_METAL_BOOTSTRAP_IS_STANDALONE)
  # The viewer's legacy LL_BUILD flags target macOS 11 globally. This explicit
  # Metal test has a target-scoped macOS 13 floor.
  target_compile_options(firestorm_metal_frame_context_test PRIVATE
    -Wno-overriding-option
    )
endif ()
target_link_options(firestorm_metal_frame_context_test PRIVATE
  "-mmacosx-version-min=${FIRESTORM_METAL_BOOTSTRAP_MIN_MACOS}"
  )
target_link_libraries(firestorm_metal_frame_context_test PRIVATE
  "${FIRESTORM_FOUNDATION_FRAMEWORK}"
  "${FIRESTORM_METAL_FRAMEWORK}"
  )
set_target_properties(firestorm_metal_frame_context_test PROPERTIES
  CXX_EXTENSIONS OFF
  CXX_STANDARD 17
  CXX_STANDARD_REQUIRED ON
  OSX_ARCHITECTURES "arm64"
  XCODE_ATTRIBUTE_CLANG_ENABLE_OBJC_ARC YES
  XCODE_ATTRIBUTE_MACOSX_DEPLOYMENT_TARGET
      "${FIRESTORM_METAL_BOOTSTRAP_MIN_MACOS}"
  )

set(FIRESTORM_METAL_RESOURCE_TEST_SOURCES
  llmetalformat.cpp
  llmetalformat.h
  llmetalframecontext-objc.mm
  llmetalframecontext.h
  llmetalframeslots.cpp
  llmetalframeslots.h
  llmetalresource-objc.mm
  llmetalresource.h
  llmetaltransfer-objc.mm
  llmetaltransfer.h
  llmetaltransientarena.cpp
  llmetaltransientarena.h
  )

add_executable(firestorm_metal_resource_transfer_test
  ${FIRESTORM_METAL_CPU_TEST_EXCLUDE_FROM_ALL}
  ${FIRESTORM_METAL_RESOURCE_TEST_SOURCES}
  resource-transfer-test-objc.mm
  )
target_compile_features(firestorm_metal_resource_transfer_test PRIVATE cxx_std_17)
target_compile_options(firestorm_metal_resource_transfer_test PRIVATE
  "$<$<COMPILE_LANGUAGE:CXX,OBJCXX>:-Wall>"
  "$<$<COMPILE_LANGUAGE:CXX,OBJCXX>:-Wextra>"
  "$<$<COMPILE_LANGUAGE:CXX,OBJCXX>:-Wpedantic>"
  "$<$<COMPILE_LANGUAGE:CXX,OBJCXX>:-Werror>"
  "$<$<COMPILE_LANGUAGE:CXX,OBJCXX>:-Wconversion>"
  "$<$<COMPILE_LANGUAGE:CXX,OBJCXX>:-Wsign-conversion>"
  "$<$<COMPILE_LANGUAGE:OBJCXX>:-fobjc-arc>"
  "$<$<COMPILE_LANGUAGE:OBJCXX>:-mmacosx-version-min=${FIRESTORM_METAL_BOOTSTRAP_MIN_MACOS}>"
  )
if (NOT FIRESTORM_METAL_BOOTSTRAP_IS_STANDALONE)
  target_compile_options(firestorm_metal_resource_transfer_test PRIVATE
    -Wno-overriding-option
    )
endif ()
target_link_options(firestorm_metal_resource_transfer_test PRIVATE
  "-mmacosx-version-min=${FIRESTORM_METAL_BOOTSTRAP_MIN_MACOS}"
  )
target_link_libraries(firestorm_metal_resource_transfer_test PRIVATE
  "${FIRESTORM_FOUNDATION_FRAMEWORK}"
  "${FIRESTORM_METAL_FRAMEWORK}"
  )
set_target_properties(firestorm_metal_resource_transfer_test PROPERTIES
  CXX_EXTENSIONS OFF
  CXX_STANDARD 17
  CXX_STANDARD_REQUIRED ON
  OSX_ARCHITECTURES "arm64"
  XCODE_ATTRIBUTE_CLANG_ENABLE_OBJC_ARC YES
  XCODE_ATTRIBUTE_MACOSX_DEPLOYMENT_TARGET
      "${FIRESTORM_METAL_BOOTSTRAP_MIN_MACOS}"
  )

add_executable(firestorm_metal_texture_subresources_test
  ${FIRESTORM_METAL_CPU_TEST_EXCLUDE_FROM_ALL}
  ${FIRESTORM_METAL_RESOURCE_TEST_SOURCES}
  texture-subresources-test-objc.mm
  )
target_compile_features(firestorm_metal_texture_subresources_test PRIVATE cxx_std_17)
target_compile_options(firestorm_metal_texture_subresources_test PRIVATE
  "$<$<COMPILE_LANGUAGE:CXX,OBJCXX>:-Wall>"
  "$<$<COMPILE_LANGUAGE:CXX,OBJCXX>:-Wextra>"
  "$<$<COMPILE_LANGUAGE:CXX,OBJCXX>:-Wpedantic>"
  "$<$<COMPILE_LANGUAGE:CXX,OBJCXX>:-Werror>"
  "$<$<COMPILE_LANGUAGE:CXX,OBJCXX>:-Wconversion>"
  "$<$<COMPILE_LANGUAGE:CXX,OBJCXX>:-Wsign-conversion>"
  "$<$<COMPILE_LANGUAGE:OBJCXX>:-fobjc-arc>"
  "$<$<COMPILE_LANGUAGE:OBJCXX>:-mmacosx-version-min=${FIRESTORM_METAL_BOOTSTRAP_MIN_MACOS}>"
  )
if (NOT FIRESTORM_METAL_BOOTSTRAP_IS_STANDALONE)
  target_compile_options(firestorm_metal_texture_subresources_test PRIVATE
    -Wno-overriding-option
    )
endif ()
target_link_options(firestorm_metal_texture_subresources_test PRIVATE
  "-mmacosx-version-min=${FIRESTORM_METAL_BOOTSTRAP_MIN_MACOS}"
  )
target_link_libraries(firestorm_metal_texture_subresources_test PRIVATE
  "${FIRESTORM_FOUNDATION_FRAMEWORK}"
  "${FIRESTORM_METAL_FRAMEWORK}"
  )
set_target_properties(firestorm_metal_texture_subresources_test PROPERTIES
  CXX_EXTENSIONS OFF
  CXX_STANDARD 17
  CXX_STANDARD_REQUIRED ON
  OSX_ARCHITECTURES "arm64"
  XCODE_ATTRIBUTE_CLANG_ENABLE_OBJC_ARC YES
  XCODE_ATTRIBUTE_MACOSX_DEPLOYMENT_TARGET
      "${FIRESTORM_METAL_BOOTSTRAP_MIN_MACOS}"
  )

add_executable(firestorm_metal_sampler_test
  ${FIRESTORM_METAL_CPU_TEST_EXCLUDE_FROM_ALL}
  ${FIRESTORM_METAL_RESOURCE_TEST_SOURCES}
  llmetalsampler-objc.mm
  llmetalsampler.cpp
  llmetalsampler.h
  sampler-test-objc.mm
  )
add_dependencies(
  firestorm_metal_sampler_test
  firestorm_metal_bootstrap_shader_library
  )
target_compile_features(firestorm_metal_sampler_test PRIVATE cxx_std_17)
target_compile_options(firestorm_metal_sampler_test PRIVATE
  "$<$<COMPILE_LANGUAGE:CXX,OBJCXX>:-Wall>"
  "$<$<COMPILE_LANGUAGE:CXX,OBJCXX>:-Wextra>"
  "$<$<COMPILE_LANGUAGE:CXX,OBJCXX>:-Wpedantic>"
  "$<$<COMPILE_LANGUAGE:CXX,OBJCXX>:-Werror>"
  "$<$<COMPILE_LANGUAGE:CXX,OBJCXX>:-Wconversion>"
  "$<$<COMPILE_LANGUAGE:CXX,OBJCXX>:-Wsign-conversion>"
  "$<$<COMPILE_LANGUAGE:OBJCXX>:-fobjc-arc>"
  "$<$<COMPILE_LANGUAGE:OBJCXX>:-mmacosx-version-min=${FIRESTORM_METAL_BOOTSTRAP_MIN_MACOS}>"
  )
if (NOT FIRESTORM_METAL_BOOTSTRAP_IS_STANDALONE)
  target_compile_options(firestorm_metal_sampler_test PRIVATE
    -Wno-overriding-option
    )
endif ()
target_link_options(firestorm_metal_sampler_test PRIVATE
  "-mmacosx-version-min=${FIRESTORM_METAL_BOOTSTRAP_MIN_MACOS}"
  )
target_link_libraries(firestorm_metal_sampler_test PRIVATE
  "${FIRESTORM_FOUNDATION_FRAMEWORK}"
  "${FIRESTORM_METAL_FRAMEWORK}"
  )
set_target_properties(firestorm_metal_sampler_test PROPERTIES
  CXX_EXTENSIONS OFF
  CXX_STANDARD 17
  CXX_STANDARD_REQUIRED ON
  OSX_ARCHITECTURES "arm64"
  XCODE_ATTRIBUTE_CLANG_ENABLE_OBJC_ARC YES
  XCODE_ATTRIBUTE_MACOSX_DEPLOYMENT_TARGET
      "${FIRESTORM_METAL_BOOTSTRAP_MIN_MACOS}"
  )

add_executable(firestorm_metal_depth_raster_test
  ${FIRESTORM_METAL_CPU_TEST_EXCLUDE_FROM_ALL}
  ${FIRESTORM_METAL_RESOURCE_TEST_SOURCES}
  depth-raster-test-objc.mm
  llmetalstate-objc.mm
  llmetalstate.h
  )
add_dependencies(
  firestorm_metal_depth_raster_test
  firestorm_metal_bootstrap_shader_library
  )
target_compile_features(firestorm_metal_depth_raster_test PRIVATE cxx_std_17)
target_compile_options(firestorm_metal_depth_raster_test PRIVATE
  "$<$<COMPILE_LANGUAGE:CXX,OBJCXX>:-Wall>"
  "$<$<COMPILE_LANGUAGE:CXX,OBJCXX>:-Wextra>"
  "$<$<COMPILE_LANGUAGE:CXX,OBJCXX>:-Wpedantic>"
  "$<$<COMPILE_LANGUAGE:CXX,OBJCXX>:-Werror>"
  "$<$<COMPILE_LANGUAGE:CXX,OBJCXX>:-Wconversion>"
  "$<$<COMPILE_LANGUAGE:CXX,OBJCXX>:-Wsign-conversion>"
  "$<$<COMPILE_LANGUAGE:OBJCXX>:-fobjc-arc>"
  "$<$<COMPILE_LANGUAGE:OBJCXX>:-mmacosx-version-min=${FIRESTORM_METAL_BOOTSTRAP_MIN_MACOS}>"
  )
if (NOT FIRESTORM_METAL_BOOTSTRAP_IS_STANDALONE)
  target_compile_options(firestorm_metal_depth_raster_test PRIVATE
    -Wno-overriding-option
    )
endif ()
target_link_options(firestorm_metal_depth_raster_test PRIVATE
  "-mmacosx-version-min=${FIRESTORM_METAL_BOOTSTRAP_MIN_MACOS}"
  )
target_link_libraries(firestorm_metal_depth_raster_test PRIVATE
  "${FIRESTORM_FOUNDATION_FRAMEWORK}"
  "${FIRESTORM_METAL_FRAMEWORK}"
  )
set_target_properties(firestorm_metal_depth_raster_test PROPERTIES
  CXX_EXTENSIONS OFF
  CXX_STANDARD 17
  CXX_STANDARD_REQUIRED ON
  OSX_ARCHITECTURES "arm64"
  XCODE_ATTRIBUTE_CLANG_ENABLE_OBJC_ARC YES
  XCODE_ATTRIBUTE_MACOSX_DEPLOYMENT_TARGET
      "${FIRESTORM_METAL_BOOTSTRAP_MIN_MACOS}"
  )

add_executable(firestorm_metal_blend_pipeline_test
  ${FIRESTORM_METAL_CPU_TEST_EXCLUDE_FROM_ALL}
  ${FIRESTORM_METAL_RESOURCE_TEST_SOURCES}
  blend-pipeline-test-objc.mm
  llmetalpipeline-objc.mm
  llmetalpipeline.cpp
  llmetalpipeline.h
  )
add_dependencies(
  firestorm_metal_blend_pipeline_test
  firestorm_metal_bootstrap_shader_library
  )
target_compile_features(firestorm_metal_blend_pipeline_test PRIVATE cxx_std_17)
target_compile_options(firestorm_metal_blend_pipeline_test PRIVATE
  "$<$<COMPILE_LANGUAGE:CXX,OBJCXX>:-Wall>"
  "$<$<COMPILE_LANGUAGE:CXX,OBJCXX>:-Wextra>"
  "$<$<COMPILE_LANGUAGE:CXX,OBJCXX>:-Wpedantic>"
  "$<$<COMPILE_LANGUAGE:CXX,OBJCXX>:-Werror>"
  "$<$<COMPILE_LANGUAGE:CXX,OBJCXX>:-Wconversion>"
  "$<$<COMPILE_LANGUAGE:CXX,OBJCXX>:-Wsign-conversion>"
  "$<$<COMPILE_LANGUAGE:OBJCXX>:-fobjc-arc>"
  "$<$<COMPILE_LANGUAGE:CXX,OBJCXX>:-mmacosx-version-min=${FIRESTORM_METAL_BOOTSTRAP_MIN_MACOS}>"
  )
if (NOT FIRESTORM_METAL_BOOTSTRAP_IS_STANDALONE)
  target_compile_options(firestorm_metal_blend_pipeline_test PRIVATE
    -Wno-overriding-option
    )
endif ()
target_link_options(firestorm_metal_blend_pipeline_test PRIVATE
  "-mmacosx-version-min=${FIRESTORM_METAL_BOOTSTRAP_MIN_MACOS}"
  )
target_link_libraries(firestorm_metal_blend_pipeline_test PRIVATE
  "${FIRESTORM_FOUNDATION_FRAMEWORK}"
  "${FIRESTORM_METAL_FRAMEWORK}"
  )
set_target_properties(firestorm_metal_blend_pipeline_test PROPERTIES
  CXX_EXTENSIONS OFF
  CXX_STANDARD 17
  CXX_STANDARD_REQUIRED ON
  OSX_ARCHITECTURES "arm64"
  XCODE_ATTRIBUTE_CLANG_ENABLE_OBJC_ARC YES
  XCODE_ATTRIBUTE_MACOSX_DEPLOYMENT_TARGET
      "${FIRESTORM_METAL_BOOTSTRAP_MIN_MACOS}"
  )

add_executable(firestorm_metal_render_pass_test
  ${FIRESTORM_METAL_CPU_TEST_EXCLUDE_FROM_ALL}
  ${FIRESTORM_METAL_RESOURCE_TEST_SOURCES}
  llmetalpipeline-objc.mm
  llmetalpipeline.cpp
  llmetalpipeline.h
  llmetalrenderpass-objc.mm
  llmetalrenderpass.h
  llmetalstate-objc.mm
  llmetalstate.h
  render-pass-test-objc.mm
  )
add_dependencies(
  firestorm_metal_render_pass_test
  firestorm_metal_bootstrap_shader_library
  )
target_compile_features(firestorm_metal_render_pass_test PRIVATE cxx_std_17)
target_compile_options(firestorm_metal_render_pass_test PRIVATE
  "$<$<COMPILE_LANGUAGE:CXX,OBJCXX>:-Wall>"
  "$<$<COMPILE_LANGUAGE:CXX,OBJCXX>:-Wextra>"
  "$<$<COMPILE_LANGUAGE:CXX,OBJCXX>:-Wpedantic>"
  "$<$<COMPILE_LANGUAGE:CXX,OBJCXX>:-Werror>"
  "$<$<COMPILE_LANGUAGE:CXX,OBJCXX>:-Wconversion>"
  "$<$<COMPILE_LANGUAGE:CXX,OBJCXX>:-Wsign-conversion>"
  "$<$<COMPILE_LANGUAGE:OBJCXX>:-fobjc-arc>"
  "$<$<COMPILE_LANGUAGE:CXX,OBJCXX>:-mmacosx-version-min=${FIRESTORM_METAL_BOOTSTRAP_MIN_MACOS}>"
  )
if (NOT FIRESTORM_METAL_BOOTSTRAP_IS_STANDALONE)
  target_compile_options(firestorm_metal_render_pass_test PRIVATE
    -Wno-overriding-option
    )
endif ()
target_link_options(firestorm_metal_render_pass_test PRIVATE
  "-mmacosx-version-min=${FIRESTORM_METAL_BOOTSTRAP_MIN_MACOS}"
  )
target_link_libraries(firestorm_metal_render_pass_test PRIVATE
  "${FIRESTORM_FOUNDATION_FRAMEWORK}"
  "${FIRESTORM_METAL_FRAMEWORK}"
  )
set_target_properties(firestorm_metal_render_pass_test PROPERTIES
  CXX_EXTENSIONS OFF
  CXX_STANDARD 17
  CXX_STANDARD_REQUIRED ON
  OSX_ARCHITECTURES "arm64"
  XCODE_ATTRIBUTE_CLANG_ENABLE_OBJC_ARC YES
  XCODE_ATTRIBUTE_MACOSX_DEPLOYMENT_TARGET
      "${FIRESTORM_METAL_BOOTSTRAP_MIN_MACOS}"
  )

add_executable(firestorm_metal_mrt_test
  ${FIRESTORM_METAL_CPU_TEST_EXCLUDE_FROM_ALL}
  ${FIRESTORM_METAL_RESOURCE_TEST_SOURCES}
  llmetalpipeline-objc.mm
  llmetalpipeline.cpp
  llmetalpipeline.h
  llmetalrenderpass-objc.mm
  llmetalrenderpass.h
  llmetalstate-objc.mm
  llmetalstate.h
  mrt-test-objc.mm
  )
add_dependencies(
  firestorm_metal_mrt_test
  firestorm_metal_bootstrap_shader_library
  )
target_compile_features(firestorm_metal_mrt_test PRIVATE cxx_std_17)
target_compile_options(firestorm_metal_mrt_test PRIVATE
  "$<$<COMPILE_LANGUAGE:CXX,OBJCXX>:-Wall>"
  "$<$<COMPILE_LANGUAGE:CXX,OBJCXX>:-Wextra>"
  "$<$<COMPILE_LANGUAGE:CXX,OBJCXX>:-Wpedantic>"
  "$<$<COMPILE_LANGUAGE:CXX,OBJCXX>:-Werror>"
  "$<$<COMPILE_LANGUAGE:CXX,OBJCXX>:-Wconversion>"
  "$<$<COMPILE_LANGUAGE:CXX,OBJCXX>:-Wsign-conversion>"
  "$<$<COMPILE_LANGUAGE:OBJCXX>:-fobjc-arc>"
  "$<$<COMPILE_LANGUAGE:CXX,OBJCXX>:-mmacosx-version-min=${FIRESTORM_METAL_BOOTSTRAP_MIN_MACOS}>"
  )
if (NOT FIRESTORM_METAL_BOOTSTRAP_IS_STANDALONE)
  target_compile_options(firestorm_metal_mrt_test PRIVATE
    -Wno-overriding-option
    )
endif ()
target_link_options(firestorm_metal_mrt_test PRIVATE
  "-mmacosx-version-min=${FIRESTORM_METAL_BOOTSTRAP_MIN_MACOS}"
  )
target_link_libraries(firestorm_metal_mrt_test PRIVATE
  "${FIRESTORM_FOUNDATION_FRAMEWORK}"
  "${FIRESTORM_METAL_FRAMEWORK}"
  )
set_target_properties(firestorm_metal_mrt_test PROPERTIES
  CXX_EXTENSIONS OFF
  CXX_STANDARD 17
  CXX_STANDARD_REQUIRED ON
  OSX_ARCHITECTURES "arm64"
  XCODE_ATTRIBUTE_CLANG_ENABLE_OBJC_ARC YES
  XCODE_ATTRIBUTE_MACOSX_DEPLOYMENT_TARGET
      "${FIRESTORM_METAL_BOOTSTRAP_MIN_MACOS}"
  )

add_executable(firestorm_metal_color_gamma_test
  ${FIRESTORM_METAL_CPU_TEST_EXCLUDE_FROM_ALL}
  ${FIRESTORM_METAL_RESOURCE_TEST_SOURCES}
  color-gamma-test-objc.mm
  llmetalpipeline-objc.mm
  llmetalpipeline.cpp
  llmetalpipeline.h
  llmetalrenderpass-objc.mm
  llmetalrenderpass.h
  )
add_dependencies(
  firestorm_metal_color_gamma_test
  firestorm_metal_bootstrap_shader_library
  )
target_compile_features(firestorm_metal_color_gamma_test PRIVATE cxx_std_17)
target_compile_options(firestorm_metal_color_gamma_test PRIVATE
  "$<$<COMPILE_LANGUAGE:CXX,OBJCXX>:-Wall>"
  "$<$<COMPILE_LANGUAGE:CXX,OBJCXX>:-Wextra>"
  "$<$<COMPILE_LANGUAGE:CXX,OBJCXX>:-Wpedantic>"
  "$<$<COMPILE_LANGUAGE:CXX,OBJCXX>:-Werror>"
  "$<$<COMPILE_LANGUAGE:CXX,OBJCXX>:-Wconversion>"
  "$<$<COMPILE_LANGUAGE:CXX,OBJCXX>:-Wsign-conversion>"
  "$<$<COMPILE_LANGUAGE:OBJCXX>:-fobjc-arc>"
  "$<$<COMPILE_LANGUAGE:CXX,OBJCXX>:-mmacosx-version-min=${FIRESTORM_METAL_BOOTSTRAP_MIN_MACOS}>"
  )
if (NOT FIRESTORM_METAL_BOOTSTRAP_IS_STANDALONE)
  target_compile_options(firestorm_metal_color_gamma_test PRIVATE
    -Wno-overriding-option
    )
endif ()
target_link_options(firestorm_metal_color_gamma_test PRIVATE
  "-mmacosx-version-min=${FIRESTORM_METAL_BOOTSTRAP_MIN_MACOS}"
  )
target_link_libraries(firestorm_metal_color_gamma_test PRIVATE
  "${FIRESTORM_FOUNDATION_FRAMEWORK}"
  "${FIRESTORM_METAL_FRAMEWORK}"
  )
set_target_properties(firestorm_metal_color_gamma_test PROPERTIES
  CXX_EXTENSIONS OFF
  CXX_STANDARD 17
  CXX_STANDARD_REQUIRED ON
  OSX_ARCHITECTURES "arm64"
  XCODE_ATTRIBUTE_CLANG_ENABLE_OBJC_ARC YES
  XCODE_ATTRIBUTE_MACOSX_DEPLOYMENT_TARGET
      "${FIRESTORM_METAL_BOOTSTRAP_MIN_MACOS}"
  )

if (FIRESTORM_BUILD_METAL_PROGRAM_ARTIFACTS)
  find_package(Python3 3.9 REQUIRED COMPONENTS Interpreter)
  find_program(FIRESTORM_GLSLANG_EXECUTABLE glslangValidator)
  find_program(FIRESTORM_SPIRV_CROSS_EXECUTABLE spirv-cross)
  find_program(FIRESTORM_SPIRV_OPT_EXECUTABLE spirv-opt)
  find_program(FIRESTORM_SPIRV_VAL_EXECUTABLE spirv-val)
  foreach (FIRESTORM_METAL_PROGRAM_TOOL
           FIRESTORM_GLSLANG_EXECUTABLE
           FIRESTORM_SPIRV_CROSS_EXECUTABLE
           FIRESTORM_SPIRV_OPT_EXECUTABLE
           FIRESTORM_SPIRV_VAL_EXECUTABLE)
    if (NOT ${FIRESTORM_METAL_PROGRAM_TOOL})
      message(FATAL_ERROR
              "FIRESTORM_BUILD_METAL_PROGRAM_ARTIFACTS requires ${FIRESTORM_METAL_PROGRAM_TOOL}")
    endif ()
  endforeach ()
  foreach (FIRESTORM_APPLE_METAL_TOOL metal metallib)
    execute_process(
      COMMAND "${FIRESTORM_XCRUN_EXECUTABLE}" -sdk macosx -find
              "${FIRESTORM_APPLE_METAL_TOOL}"
      RESULT_VARIABLE FIRESTORM_APPLE_METAL_TOOL_RESULT
      OUTPUT_QUIET
      ERROR_VARIABLE FIRESTORM_APPLE_METAL_TOOL_ERROR
      )
    if (NOT FIRESTORM_APPLE_METAL_TOOL_RESULT EQUAL 0)
      message(FATAL_ERROR
              "The optional Apple Metal toolchain is missing ${FIRESTORM_APPLE_METAL_TOOL}: ${FIRESTORM_APPLE_METAL_TOOL_ERROR}")
    endif ()
  endforeach ()

  set(FIRESTORM_REPOSITORY_ROOT "${CMAKE_CURRENT_SOURCE_DIR}/../../..")
  set(FIRESTORM_METAL_PROGRAM_SCRIPT_DIR
      "${FIRESTORM_REPOSITORY_ROOT}/scripts/metal")
  set(FIRESTORM_METAL_PROGRAM_MANIFEST
      "${FIRESTORM_REPOSITORY_ROOT}/doc/metal/shader-spike.json")
  get_filename_component(FIRESTORM_METAL_PROGRAM_BINARY_DIR
                         "${CMAKE_CURRENT_BINARY_DIR}"
                         REALPATH)
  set(FIRESTORM_METAL_PROGRAM_OUTPUT_DIR
      "${FIRESTORM_METAL_PROGRAM_BINARY_DIR}/declared-program-artifacts")
  set(FIRESTORM_METAL_PROGRAM_CATALOG_DIR
      "${FIRESTORM_METAL_PROGRAM_OUTPUT_DIR}/firestorm-declared-programs")
  set(FIRESTORM_METAL_PROGRAM_LIBRARY
      "${FIRESTORM_METAL_PROGRAM_CATALOG_DIR}/firestorm-declared-programs.metallib")
  set(FIRESTORM_METAL_PROGRAM_JSON
      "${FIRESTORM_METAL_PROGRAM_CATALOG_DIR}/firestorm-declared-programs.json")
  set(FIRESTORM_METAL_PROGRAM_HEADER
      "${FIRESTORM_METAL_PROGRAM_CATALOG_DIR}/firestorm-declared-programs.h")
  set(FIRESTORM_METAL_PROGRAM_SOURCE
      "${FIRESTORM_METAL_PROGRAM_CATALOG_DIR}/firestorm-declared-programs.cpp")

  file(GLOB_RECURSE FIRESTORM_METAL_PROGRAM_SHADER_INPUTS CONFIGURE_DEPENDS
       "${FIRESTORM_REPOSITORY_ROOT}/indra/newview/app_settings/shaders/*.glsl")
  set(FIRESTORM_METAL_PROGRAM_SOURCE_CONTRACTS
      "${FIRESTORM_REPOSITORY_ROOT}/indra/newview/pipeline.cpp"
      "${FIRESTORM_REPOSITORY_ROOT}/indra/newview/llviewershadermgr.cpp"
      "${FIRESTORM_REPOSITORY_ROOT}/indra/llrender/llvertexbuffer.cpp"
      "${FIRESTORM_REPOSITORY_ROOT}/indra/llrender/llvertexbuffer.h"
      "${FIRESTORM_REPOSITORY_ROOT}/indra/llrender/llshadermgr.cpp"
      "${FIRESTORM_REPOSITORY_ROOT}/indra/llwindow/metal/llmetalbootstrap-objc.mm"
      "${FIRESTORM_REPOSITORY_ROOT}/indra/newview/llreflectionmapmanager.cpp"
      "${FIRESTORM_REPOSITORY_ROOT}/indra/newview/app_settings/settings.xml"
      )
  set(FIRESTORM_METAL_PROGRAM_TOOL_DIRS)
  foreach (FIRESTORM_METAL_PROGRAM_TOOL_PATH
           "${FIRESTORM_GLSLANG_EXECUTABLE}"
           "${FIRESTORM_SPIRV_CROSS_EXECUTABLE}"
           "${FIRESTORM_SPIRV_OPT_EXECUTABLE}"
           "${FIRESTORM_SPIRV_VAL_EXECUTABLE}")
    get_filename_component(FIRESTORM_METAL_PROGRAM_TOOL_DIR
                           "${FIRESTORM_METAL_PROGRAM_TOOL_PATH}" DIRECTORY)
    list(APPEND FIRESTORM_METAL_PROGRAM_TOOL_DIRS
         "${FIRESTORM_METAL_PROGRAM_TOOL_DIR}")
  endforeach ()
  list(REMOVE_DUPLICATES FIRESTORM_METAL_PROGRAM_TOOL_DIRS)
  list(JOIN FIRESTORM_METAL_PROGRAM_TOOL_DIRS ":"
       FIRESTORM_METAL_PROGRAM_TOOL_PATH)

  add_custom_command(
    OUTPUT
      "${FIRESTORM_METAL_PROGRAM_LIBRARY}"
      "${FIRESTORM_METAL_PROGRAM_JSON}"
      "${FIRESTORM_METAL_PROGRAM_HEADER}"
      "${FIRESTORM_METAL_PROGRAM_SOURCE}"
    COMMAND "${CMAKE_COMMAND}" -E env
            "PATH=${FIRESTORM_METAL_PROGRAM_TOOL_PATH}:$ENV{PATH}"
            "${Python3_EXECUTABLE}"
            "${FIRESTORM_METAL_PROGRAM_SCRIPT_DIR}/shader_spike.py"
            --manifest "${FIRESTORM_METAL_PROGRAM_MANIFEST}"
            --output "${FIRESTORM_METAL_PROGRAM_OUTPUT_DIR}"
            --allow-empty-output
    DEPENDS
      "${FIRESTORM_METAL_PROGRAM_MANIFEST}"
      "${FIRESTORM_METAL_PROGRAM_SCRIPT_DIR}/runtime_programs.py"
      "${FIRESTORM_METAL_PROGRAM_SCRIPT_DIR}/shader_spike.py"
      "${FIRESTORM_METAL_PROGRAM_SCRIPT_DIR}/spirv_locations.py"
      "${FIRESTORM_METAL_PROGRAM_SCRIPT_DIR}/validate_metal_pipeline.mm"
      ${FIRESTORM_METAL_PROGRAM_SHADER_INPUTS}
      ${FIRESTORM_METAL_PROGRAM_SOURCE_CONTRACTS}
    COMMENT "Generating and validating the declared Firestorm Metal programs"
    VERBATIM
    )
  add_custom_target(firestorm_metal_declared_programs
    DEPENDS
      "${FIRESTORM_METAL_PROGRAM_LIBRARY}"
      "${FIRESTORM_METAL_PROGRAM_JSON}"
      "${FIRESTORM_METAL_PROGRAM_HEADER}"
      "${FIRESTORM_METAL_PROGRAM_SOURCE}"
    )
  set_source_files_properties(
    "${FIRESTORM_METAL_PROGRAM_LIBRARY}"
    "${FIRESTORM_METAL_PROGRAM_HEADER}"
    "${FIRESTORM_METAL_PROGRAM_SOURCE}"
    PROPERTIES GENERATED TRUE
    )

  add_library(firestorm_metal_artifact_runtime STATIC EXCLUDE_FROM_ALL
    llmetalformat.cpp
    llmetalformat.h
    llmetalframecontext-objc.mm
    llmetalframecontext.h
    llmetalframeslots.cpp
    llmetalframeslots.h
    llmetalgeometry.h
    llmetalgeometry-objc.mm
    llmetalpipeline.cpp
    llmetalpipeline.h
    llmetalpipeline-objc.mm
    llmetalprogram.cpp
    llmetalprogram.h
    llmetalprogram-objc.mm
    llmetalresource.h
    llmetalresource-objc.mm
    llmetalsampler.cpp
    llmetalsampler.h
    llmetalsampler-objc.mm
    llmetalstate.h
    llmetaltransfer.h
    llmetaltransfer-objc.mm
    llmetaltransientarena.cpp
    llmetaltransientarena.h
    llmetalvertexlayout.cpp
    llmetalvertexlayout.h
    "${FIRESTORM_METAL_PROGRAM_HEADER}"
    "${FIRESTORM_METAL_PROGRAM_SOURCE}"
    )
  add_dependencies(firestorm_metal_artifact_runtime
                   firestorm_metal_declared_programs)
  target_include_directories(firestorm_metal_artifact_runtime PUBLIC
    "${CMAKE_CURRENT_SOURCE_DIR}"
    "${FIRESTORM_METAL_PROGRAM_CATALOG_DIR}"
    )
  target_compile_features(firestorm_metal_artifact_runtime PUBLIC cxx_std_17)
  target_compile_options(firestorm_metal_artifact_runtime PRIVATE
    "$<$<COMPILE_LANGUAGE:CXX,OBJCXX>:-Wall>"
    "$<$<COMPILE_LANGUAGE:CXX,OBJCXX>:-Wextra>"
    "$<$<COMPILE_LANGUAGE:CXX,OBJCXX>:-Wpedantic>"
    "$<$<COMPILE_LANGUAGE:CXX,OBJCXX>:-Werror>"
    "$<$<COMPILE_LANGUAGE:CXX,OBJCXX>:-Wconversion>"
    "$<$<COMPILE_LANGUAGE:CXX,OBJCXX>:-Wsign-conversion>"
    "$<$<COMPILE_LANGUAGE:OBJCXX>:-fobjc-arc>"
    "$<$<COMPILE_LANGUAGE:CXX,OBJCXX>:-mmacosx-version-min=${FIRESTORM_METAL_BOOTSTRAP_MIN_MACOS}>"
    )
  if (NOT FIRESTORM_METAL_BOOTSTRAP_IS_STANDALONE)
    target_compile_options(firestorm_metal_artifact_runtime PRIVATE
      -Wno-overriding-option
      )
  endif ()
  target_link_options(firestorm_metal_artifact_runtime INTERFACE
    "-mmacosx-version-min=${FIRESTORM_METAL_BOOTSTRAP_MIN_MACOS}"
    )
  target_link_libraries(firestorm_metal_artifact_runtime PUBLIC
    "${FIRESTORM_FOUNDATION_FRAMEWORK}"
    "${FIRESTORM_METAL_FRAMEWORK}"
    )
  set_target_properties(firestorm_metal_artifact_runtime PROPERTIES
    CXX_EXTENSIONS OFF
    CXX_STANDARD 17
    CXX_STANDARD_REQUIRED ON
    OSX_ARCHITECTURES "arm64"
    XCODE_ATTRIBUTE_CLANG_ENABLE_OBJC_ARC YES
    XCODE_ATTRIBUTE_MACOSX_DEPLOYMENT_TARGET
        "${FIRESTORM_METAL_BOOTSTRAP_MIN_MACOS}"
    )

  if (NOT FIRESTORM_METAL_BOOTSTRAP_IS_STANDALONE)
    set(FIRESTORM_METAL_PROGRAM_LIBRARY
        "${FIRESTORM_METAL_PROGRAM_LIBRARY}" PARENT_SCOPE)
  endif ()

  add_executable(firestorm_metal_program_library_test
    ${FIRESTORM_METAL_CPU_TEST_EXCLUDE_FROM_ALL}
    llmetalformat.h
    llmetalframecontext.h
    llmetalprogram.h
    llmetalprogram.cpp
    llmetalprogram-objc.mm
    llmetalvertexlayout.h
    llmetalvertexlayout.cpp
    program-library-test-objc.mm
    "${FIRESTORM_METAL_PROGRAM_HEADER}"
    "${FIRESTORM_METAL_PROGRAM_SOURCE}"
    )
  add_dependencies(firestorm_metal_program_library_test
                   firestorm_metal_declared_programs)
  target_include_directories(firestorm_metal_program_library_test PRIVATE
    "${CMAKE_CURRENT_SOURCE_DIR}"
    "${FIRESTORM_METAL_PROGRAM_CATALOG_DIR}"
    )
  target_compile_features(firestorm_metal_program_library_test PRIVATE cxx_std_17)
  target_compile_options(firestorm_metal_program_library_test PRIVATE
    "$<$<COMPILE_LANGUAGE:CXX,OBJCXX>:-Wall>"
    "$<$<COMPILE_LANGUAGE:CXX,OBJCXX>:-Wextra>"
    "$<$<COMPILE_LANGUAGE:CXX,OBJCXX>:-Wpedantic>"
    "$<$<COMPILE_LANGUAGE:CXX,OBJCXX>:-Werror>"
    "$<$<COMPILE_LANGUAGE:CXX,OBJCXX>:-Wconversion>"
    "$<$<COMPILE_LANGUAGE:CXX,OBJCXX>:-Wsign-conversion>"
    "$<$<COMPILE_LANGUAGE:OBJCXX>:-fobjc-arc>"
    "$<$<COMPILE_LANGUAGE:CXX,OBJCXX>:-mmacosx-version-min=${FIRESTORM_METAL_BOOTSTRAP_MIN_MACOS}>"
    )
  if (NOT FIRESTORM_METAL_BOOTSTRAP_IS_STANDALONE)
    target_compile_options(firestorm_metal_program_library_test PRIVATE
      -Wno-overriding-option
      )
  endif ()
  target_link_options(firestorm_metal_program_library_test PRIVATE
    "-mmacosx-version-min=${FIRESTORM_METAL_BOOTSTRAP_MIN_MACOS}"
    )
  target_link_libraries(firestorm_metal_program_library_test PRIVATE
    "${FIRESTORM_FOUNDATION_FRAMEWORK}"
    "${FIRESTORM_METAL_FRAMEWORK}"
    )
  set_target_properties(firestorm_metal_program_library_test PROPERTIES
    CXX_EXTENSIONS OFF
    CXX_STANDARD 17
    CXX_STANDARD_REQUIRED ON
    OSX_ARCHITECTURES "arm64"
    XCODE_ATTRIBUTE_CLANG_ENABLE_OBJC_ARC YES
    XCODE_ATTRIBUTE_MACOSX_DEPLOYMENT_TARGET
        "${FIRESTORM_METAL_BOOTSTRAP_MIN_MACOS}"
    )

  add_executable(firestorm_metal_artifact_vertex_index_test
    ${FIRESTORM_METAL_CPU_TEST_EXCLUDE_FROM_ALL}
    ${FIRESTORM_METAL_RESOURCE_TEST_SOURCES}
    artifact-vertex-index-test-objc.mm
    llmetalgeometry.h
    llmetalgeometry-objc.mm
    llmetalpipeline.h
    llmetalpipeline.cpp
    llmetalpipeline-objc.mm
    llmetalprogram.h
    llmetalprogram.cpp
    llmetalprogram-objc.mm
    llmetalrenderpass.h
    llmetalrenderpass-objc.mm
    llmetalstate.h
    llmetalvertexlayout.h
    llmetalvertexlayout.cpp
    "${FIRESTORM_METAL_PROGRAM_HEADER}"
    "${FIRESTORM_METAL_PROGRAM_SOURCE}"
    )
  add_dependencies(firestorm_metal_artifact_vertex_index_test
                   firestorm_metal_declared_programs)
  target_include_directories(firestorm_metal_artifact_vertex_index_test PRIVATE
    "${CMAKE_CURRENT_SOURCE_DIR}"
    "${FIRESTORM_METAL_PROGRAM_CATALOG_DIR}"
    )
  target_compile_features(firestorm_metal_artifact_vertex_index_test PRIVATE
                          cxx_std_17)
  target_compile_options(firestorm_metal_artifact_vertex_index_test PRIVATE
    "$<$<COMPILE_LANGUAGE:CXX,OBJCXX>:-Wall>"
    "$<$<COMPILE_LANGUAGE:CXX,OBJCXX>:-Wextra>"
    "$<$<COMPILE_LANGUAGE:CXX,OBJCXX>:-Wpedantic>"
    "$<$<COMPILE_LANGUAGE:CXX,OBJCXX>:-Werror>"
    "$<$<COMPILE_LANGUAGE:CXX,OBJCXX>:-Wconversion>"
    "$<$<COMPILE_LANGUAGE:CXX,OBJCXX>:-Wsign-conversion>"
    "$<$<COMPILE_LANGUAGE:OBJCXX>:-fobjc-arc>"
    "$<$<COMPILE_LANGUAGE:CXX,OBJCXX>:-mmacosx-version-min=${FIRESTORM_METAL_BOOTSTRAP_MIN_MACOS}>"
    )
  if (NOT FIRESTORM_METAL_BOOTSTRAP_IS_STANDALONE)
    target_compile_options(firestorm_metal_artifact_vertex_index_test PRIVATE
      -Wno-overriding-option
      )
  endif ()
  target_link_options(firestorm_metal_artifact_vertex_index_test PRIVATE
    "-mmacosx-version-min=${FIRESTORM_METAL_BOOTSTRAP_MIN_MACOS}"
    )
  target_link_libraries(firestorm_metal_artifact_vertex_index_test PRIVATE
    "${FIRESTORM_FOUNDATION_FRAMEWORK}"
    "${FIRESTORM_METAL_FRAMEWORK}"
    )
  set_target_properties(firestorm_metal_artifact_vertex_index_test PROPERTIES
    CXX_EXTENSIONS OFF
    CXX_STANDARD 17
    CXX_STANDARD_REQUIRED ON
    OSX_ARCHITECTURES "arm64"
    XCODE_ATTRIBUTE_CLANG_ENABLE_OBJC_ARC YES
    XCODE_ATTRIBUTE_MACOSX_DEPLOYMENT_TARGET
        "${FIRESTORM_METAL_BOOTSTRAP_MIN_MACOS}"
    )
endif ()

if (FIRESTORM_METAL_BOOTSTRAP_IS_STANDALONE)
  message(STATUS "Configuring the standalone Firestorm Metal bootstrap")

  include(CTest)
  if (BUILD_TESTING)
    add_test(
      NAME firestorm_metal_frame_contracts
      COMMAND firestorm_metal_frame_contracts_test
      )
    add_test(
      NAME firestorm_metal_resource_layout
      COMMAND firestorm_metal_resource_layout_test
      )
    set_tests_properties(
      firestorm_metal_resource_layout
      PROPERTIES TIMEOUT 10
      )
    add_test(
      NAME firestorm_metal_frame_context
      COMMAND "${CMAKE_COMMAND}" -E env
              MTL_DEBUG_LAYER=1
              MTL_SHADER_VALIDATION=1
              "$<TARGET_FILE:firestorm_metal_frame_context_test>"
      )
    set_tests_properties(
      firestorm_metal_frame_context
      PROPERTIES
        LABELS "metal;gpu"
        TIMEOUT 30
      )
    add_test(
      NAME firestorm_metal_resource_transfer
      COMMAND "${CMAKE_COMMAND}" -E env
              MTL_DEBUG_LAYER=1
              MTL_SHADER_VALIDATION=1
              "$<TARGET_FILE:firestorm_metal_resource_transfer_test>"
      )
    set_tests_properties(
      firestorm_metal_resource_transfer
      PROPERTIES
        LABELS "metal;gpu"
        TIMEOUT 30
      )
    add_test(
      NAME firestorm_metal_texture_subresources
      COMMAND "${CMAKE_COMMAND}" -E env
              MTL_DEBUG_LAYER=1
              MTL_SHADER_VALIDATION=1
              "$<TARGET_FILE:firestorm_metal_texture_subresources_test>"
      )
    set_tests_properties(
      firestorm_metal_texture_subresources
      PROPERTIES
        LABELS "metal;gpu"
        TIMEOUT 30
      )
    add_test(
      NAME firestorm_metal_sampler
      COMMAND "${CMAKE_COMMAND}" -E env
              MTL_DEBUG_LAYER=1
              MTL_SHADER_VALIDATION=1
              "$<TARGET_FILE:firestorm_metal_sampler_test>"
              --metallib "${FIRESTORM_METAL_LIBRARY}"
      )
    set_tests_properties(
      firestorm_metal_sampler
      PROPERTIES
        LABELS "metal;gpu"
        TIMEOUT 30
      )
    add_test(
      NAME firestorm_metal_depth_raster
      COMMAND "${CMAKE_COMMAND}" -E env
              MTL_DEBUG_LAYER=1
              MTL_SHADER_VALIDATION=1
              "$<TARGET_FILE:firestorm_metal_depth_raster_test>"
              --metallib "${FIRESTORM_METAL_LIBRARY}"
      )
    set_tests_properties(
      firestorm_metal_depth_raster
      PROPERTIES
        LABELS "metal;gpu"
        TIMEOUT 30
      )
    add_test(
      NAME firestorm_metal_blend_pipeline
      COMMAND "${CMAKE_COMMAND}" -E env
              MTL_DEBUG_LAYER=1
              MTL_SHADER_VALIDATION=1
              "$<TARGET_FILE:firestorm_metal_blend_pipeline_test>"
              --metallib "${FIRESTORM_METAL_LIBRARY}"
      )
    set_tests_properties(
      firestorm_metal_blend_pipeline
      PROPERTIES
        LABELS "metal;gpu"
        TIMEOUT 30
      )
    add_test(
      NAME firestorm_metal_render_pass
      COMMAND "${CMAKE_COMMAND}" -E env
              MTL_DEBUG_LAYER=1
              MTL_SHADER_VALIDATION=1
              "$<TARGET_FILE:firestorm_metal_render_pass_test>"
              --metallib "${FIRESTORM_METAL_LIBRARY}"
      )
    set_tests_properties(
      firestorm_metal_render_pass
      PROPERTIES
        LABELS "metal;gpu"
        TIMEOUT 30
      )
    add_test(
      NAME firestorm_metal_mrt
      COMMAND "${CMAKE_COMMAND}" -E env
              MTL_DEBUG_LAYER=1
              MTL_SHADER_VALIDATION=1
              "$<TARGET_FILE:firestorm_metal_mrt_test>"
              --metallib "${FIRESTORM_METAL_LIBRARY}"
      )
    set_tests_properties(
      firestorm_metal_mrt
      PROPERTIES
        LABELS "metal;gpu"
        TIMEOUT 30
      )
    add_test(
      NAME firestorm_metal_color_gamma
      COMMAND "${CMAKE_COMMAND}" -E env
              MTL_DEBUG_LAYER=1
              MTL_SHADER_VALIDATION=1
              "$<TARGET_FILE:firestorm_metal_color_gamma_test>"
              --metallib "${FIRESTORM_METAL_LIBRARY}"
      )
    set_tests_properties(
      firestorm_metal_color_gamma
      PROPERTIES
        LABELS "metal;gpu"
        TIMEOUT 30
      )
    if (FIRESTORM_BUILD_METAL_PROGRAM_ARTIFACTS)
      add_test(
        NAME firestorm_metal_program_library
        COMMAND "${CMAKE_COMMAND}" -E env
                MTL_DEBUG_LAYER=1
                MTL_SHADER_VALIDATION=1
                "$<TARGET_FILE:firestorm_metal_program_library_test>"
                --metallib "${FIRESTORM_METAL_PROGRAM_LIBRARY}"
        )
      set_tests_properties(
        firestorm_metal_program_library
        PROPERTIES
          LABELS "metal;gpu;shader-artifact"
          TIMEOUT 120
        )
      add_test(
        NAME firestorm_metal_program_library_digest_rejection
        COMMAND "${Python3_EXECUTABLE}" -c [=[
import pathlib
import subprocess
import sys

executable = pathlib.Path(sys.argv[1])
source = pathlib.Path(sys.argv[2])
corrupted = pathlib.Path(sys.argv[3])
data = bytearray(source.read_bytes())
if not data:
    raise SystemExit("generated metallib is empty")
data[len(data) // 2] ^= 1
corrupted.write_bytes(data)
try:
    result = subprocess.run(
        [str(executable), "--metallib", str(corrupted)],
        capture_output=True,
        text=True,
        check=False,
    )
    if result.returncode == 0:
        raise SystemExit("bit-flipped metallib was accepted")
    if "SHA-256 does not match" not in result.stderr:
        sys.stderr.write(result.stdout)
        sys.stderr.write(result.stderr)
        raise SystemExit("bit-flipped metallib did not fail at digest verification")
finally:
    corrupted.unlink(missing_ok=True)
]=]
                "$<TARGET_FILE:firestorm_metal_program_library_test>"
                "${FIRESTORM_METAL_PROGRAM_LIBRARY}"
                "${CMAKE_CURRENT_BINARY_DIR}/bit-flipped-declared-programs.metallib"
        )
      set_tests_properties(
        firestorm_metal_program_library_digest_rejection
        PROPERTIES
          LABELS "metal;shader-artifact;negative"
          TIMEOUT 30
        )
      add_test(
        NAME firestorm_metal_artifact_vertex_index
        COMMAND "${CMAKE_COMMAND}" -E env
                MTL_DEBUG_LAYER=1
                MTL_SHADER_VALIDATION=1
                "$<TARGET_FILE:firestorm_metal_artifact_vertex_index_test>"
                --metallib "${FIRESTORM_METAL_PROGRAM_LIBRARY}"
        )
      set_tests_properties(
        firestorm_metal_artifact_vertex_index
        PROPERTIES
          LABELS "metal;gpu;shader-artifact"
          TIMEOUT 120
        )
      if (NOT FIRESTORM_METAL_OPENGL_ORACLE_WORKTREE STREQUAL "")
        if (NOT IS_DIRECTORY "${FIRESTORM_METAL_OPENGL_ORACLE_WORKTREE}")
          message(FATAL_ERROR
                  "FIRESTORM_METAL_OPENGL_ORACLE_WORKTREE is not a directory: ${FIRESTORM_METAL_OPENGL_ORACLE_WORKTREE}")
        endif ()

        get_filename_component(FIRESTORM_METAL_OPENGL_ORACLE_WORKTREE_REALPATH
                               "${FIRESTORM_METAL_OPENGL_ORACLE_WORKTREE}"
                               REALPATH
                               BASE_DIR "${CMAKE_CURRENT_BINARY_DIR}")
        set(FIRESTORM_METAL_OPENGL_ORACLE_WORKTREE
            "${FIRESTORM_METAL_OPENGL_ORACLE_WORKTREE_REALPATH}"
            CACHE PATH
            "Pinned detached Firestorm worktree used only by the opt-in OpenGL semantic oracle"
            FORCE)

        set(FIRESTORM_METAL_ORACLE_PINNED_COMMIT
            "1e8fd5491bde91fe6daca7d78f217a4d46084a5b")
        find_package(Git REQUIRED)
        string(REPLACE "\\" "\\\\" FIRESTORM_METAL_ORACLE_GIT_EXECUTABLE_ESCAPED
                       "${GIT_EXECUTABLE}")
        string(REPLACE "\"" "\\\"" FIRESTORM_METAL_ORACLE_GIT_EXECUTABLE_ESCAPED
                       "${FIRESTORM_METAL_ORACLE_GIT_EXECUTABLE_ESCAPED}")
        set(FIRESTORM_METAL_FXAA_SEMANTIC_CONFIG_DIR
            "${CMAKE_CURRENT_BINARY_DIR}/fxaa-semantic-config")
        set(FIRESTORM_METAL_FXAA_SEMANTIC_CONFIG_HEADER
            "${FIRESTORM_METAL_FXAA_SEMANTIC_CONFIG_DIR}/firestorm_metal_fxaa_semantic_config.h")
        file(MAKE_DIRECTORY "${FIRESTORM_METAL_FXAA_SEMANTIC_CONFIG_DIR}")
        file(GENERATE
          OUTPUT "${FIRESTORM_METAL_FXAA_SEMANTIC_CONFIG_HEADER}"
          CONTENT
            "#pragma once\n\n#define FIRESTORM_METAL_ORACLE_GIT_EXECUTABLE \"${FIRESTORM_METAL_ORACLE_GIT_EXECUTABLE_ESCAPED}\"\n#define FIRESTORM_METAL_ORACLE_PINNED_COMMIT \"${FIRESTORM_METAL_ORACLE_PINNED_COMMIT}\"\n"
          )
        execute_process(
          COMMAND "${GIT_EXECUTABLE}" --no-optional-locks -C
                  "${FIRESTORM_METAL_OPENGL_ORACLE_WORKTREE}"
                  rev-parse --show-toplevel
          RESULT_VARIABLE FIRESTORM_METAL_OPENGL_ORACLE_ROOT_RESULT
          OUTPUT_VARIABLE FIRESTORM_METAL_OPENGL_ORACLE_ROOT
          ERROR_VARIABLE FIRESTORM_METAL_OPENGL_ORACLE_ROOT_ERROR
          OUTPUT_STRIP_TRAILING_WHITESPACE
          )
        if (NOT FIRESTORM_METAL_OPENGL_ORACLE_ROOT_RESULT EQUAL 0)
          message(FATAL_ERROR
                  "FIRESTORM_METAL_OPENGL_ORACLE_WORKTREE is not a Git worktree: ${FIRESTORM_METAL_OPENGL_ORACLE_ROOT_ERROR}")
        endif ()
        get_filename_component(FIRESTORM_METAL_OPENGL_ORACLE_ROOT_REALPATH
                               "${FIRESTORM_METAL_OPENGL_ORACLE_ROOT}"
                               REALPATH)
        if (NOT FIRESTORM_METAL_OPENGL_ORACLE_ROOT_REALPATH STREQUAL
            FIRESTORM_METAL_OPENGL_ORACLE_WORKTREE)
          message(FATAL_ERROR
                  "FIRESTORM_METAL_OPENGL_ORACLE_WORKTREE must name the worktree root: ${FIRESTORM_METAL_OPENGL_ORACLE_ROOT_REALPATH}")
        endif ()

        execute_process(
          COMMAND "${GIT_EXECUTABLE}" --no-optional-locks -C
                  "${FIRESTORM_METAL_OPENGL_ORACLE_WORKTREE}"
                  rev-parse --verify "HEAD^{commit}"
          RESULT_VARIABLE FIRESTORM_METAL_OPENGL_ORACLE_HEAD_RESULT
          OUTPUT_VARIABLE FIRESTORM_METAL_OPENGL_ORACLE_HEAD
          ERROR_VARIABLE FIRESTORM_METAL_OPENGL_ORACLE_HEAD_ERROR
          OUTPUT_STRIP_TRAILING_WHITESPACE
          )
        if (NOT FIRESTORM_METAL_OPENGL_ORACLE_HEAD_RESULT EQUAL 0)
          message(FATAL_ERROR
                  "Could not read FIRESTORM_METAL_OPENGL_ORACLE_WORKTREE HEAD: ${FIRESTORM_METAL_OPENGL_ORACLE_HEAD_ERROR}")
        endif ()
        if (NOT FIRESTORM_METAL_OPENGL_ORACLE_HEAD STREQUAL
            FIRESTORM_METAL_ORACLE_PINNED_COMMIT)
          message(FATAL_ERROR
                  "FIRESTORM_METAL_OPENGL_ORACLE_WORKTREE must be at ${FIRESTORM_METAL_ORACLE_PINNED_COMMIT}, found ${FIRESTORM_METAL_OPENGL_ORACLE_HEAD}")
        endif ()

        execute_process(
          COMMAND "${GIT_EXECUTABLE}" --no-optional-locks -C
                  "${FIRESTORM_METAL_OPENGL_ORACLE_WORKTREE}"
                  symbolic-ref --quiet HEAD
          RESULT_VARIABLE FIRESTORM_METAL_OPENGL_ORACLE_SYMBOLIC_HEAD_RESULT
          OUTPUT_QUIET
          ERROR_QUIET
          )
        if (FIRESTORM_METAL_OPENGL_ORACLE_SYMBOLIC_HEAD_RESULT EQUAL 0)
          message(FATAL_ERROR
                  "FIRESTORM_METAL_OPENGL_ORACLE_WORKTREE must have a detached HEAD")
        elseif (NOT FIRESTORM_METAL_OPENGL_ORACLE_SYMBOLIC_HEAD_RESULT EQUAL 1)
          message(FATAL_ERROR
                  "Could not verify detached HEAD in FIRESTORM_METAL_OPENGL_ORACLE_WORKTREE")
        endif ()

        execute_process(
          COMMAND "${GIT_EXECUTABLE}" --no-optional-locks -C
                  "${FIRESTORM_METAL_OPENGL_ORACLE_WORKTREE}"
                  status --porcelain=v1
          RESULT_VARIABLE FIRESTORM_METAL_OPENGL_ORACLE_STATUS_RESULT
          OUTPUT_VARIABLE FIRESTORM_METAL_OPENGL_ORACLE_STATUS
          ERROR_VARIABLE FIRESTORM_METAL_OPENGL_ORACLE_STATUS_ERROR
          OUTPUT_STRIP_TRAILING_WHITESPACE
          )
        if (NOT FIRESTORM_METAL_OPENGL_ORACLE_STATUS_RESULT EQUAL 0)
          message(FATAL_ERROR
                  "Could not inspect FIRESTORM_METAL_OPENGL_ORACLE_WORKTREE: ${FIRESTORM_METAL_OPENGL_ORACLE_STATUS_ERROR}")
        endif ()
        if (NOT FIRESTORM_METAL_OPENGL_ORACLE_STATUS STREQUAL "")
          message(FATAL_ERROR
                  "FIRESTORM_METAL_OPENGL_ORACLE_WORKTREE has changes:\n${FIRESTORM_METAL_OPENGL_ORACLE_STATUS}")
        endif ()

        find_library(FIRESTORM_OPENGL_FRAMEWORK OpenGL)
        if (NOT FIRESTORM_OPENGL_FRAMEWORK)
          message(FATAL_ERROR
                  "The opt-in FXAA semantic oracle requires OpenGL.framework")
        endif ()

        set_source_files_properties(
          fxaa-semantic-test-objc.mm
          PROPERTIES SKIP_PRECOMPILE_HEADERS TRUE
          )
        add_executable(firestorm_metal_fxaa_semantic_test
          fxaa-semantic-test-objc.mm
          )
        target_compile_features(firestorm_metal_fxaa_semantic_test PRIVATE
                                cxx_std_17)
        target_compile_options(firestorm_metal_fxaa_semantic_test PRIVATE
          "$<$<COMPILE_LANGUAGE:OBJCXX>:-Wall>"
          "$<$<COMPILE_LANGUAGE:OBJCXX>:-Wextra>"
          "$<$<COMPILE_LANGUAGE:OBJCXX>:-Wpedantic>"
          "$<$<COMPILE_LANGUAGE:OBJCXX>:-Werror>"
          "$<$<COMPILE_LANGUAGE:OBJCXX>:-Wconversion>"
          "$<$<COMPILE_LANGUAGE:OBJCXX>:-Wsign-conversion>"
          "$<$<COMPILE_LANGUAGE:OBJCXX>:-fobjc-arc>"
          "$<$<COMPILE_LANGUAGE:OBJCXX>:-mmacosx-version-min=${FIRESTORM_METAL_BOOTSTRAP_MIN_MACOS}>"
          )
        target_compile_definitions(firestorm_metal_fxaa_semantic_test PRIVATE
          GL_SILENCE_DEPRECATION
          )
        target_include_directories(firestorm_metal_fxaa_semantic_test PRIVATE
          "${FIRESTORM_METAL_FXAA_SEMANTIC_CONFIG_DIR}"
          )
        target_link_options(firestorm_metal_fxaa_semantic_test PRIVATE
          "-mmacosx-version-min=${FIRESTORM_METAL_BOOTSTRAP_MIN_MACOS}"
          )
        target_link_libraries(firestorm_metal_fxaa_semantic_test PRIVATE
          firestorm_metal_artifact_runtime
          "${FIRESTORM_FOUNDATION_FRAMEWORK}"
          "${FIRESTORM_METAL_FRAMEWORK}"
          "${FIRESTORM_OPENGL_FRAMEWORK}"
          )
        set_target_properties(firestorm_metal_fxaa_semantic_test PROPERTIES
          CXX_EXTENSIONS OFF
          CXX_STANDARD 17
          CXX_STANDARD_REQUIRED ON
          OSX_ARCHITECTURES "arm64"
          XCODE_ATTRIBUTE_CLANG_ENABLE_OBJC_ARC YES
          XCODE_ATTRIBUTE_MACOSX_DEPLOYMENT_TARGET
              "${FIRESTORM_METAL_BOOTSTRAP_MIN_MACOS}"
          )

        add_test(
          NAME firestorm_metal_fxaa_semantic
          COMMAND "${CMAKE_COMMAND}" -E env
                  MTL_DEBUG_LAYER=1
                  MTL_SHADER_VALIDATION=1
                  "$<TARGET_FILE:firestorm_metal_fxaa_semantic_test>"
                  --metallib "${FIRESTORM_METAL_PROGRAM_LIBRARY}"
                  --artifact-root "${FIRESTORM_METAL_PROGRAM_OUTPUT_DIR}"
                  --oracle-worktree
                  "${FIRESTORM_METAL_OPENGL_ORACLE_WORKTREE}"
          )
        set_tests_properties(
          firestorm_metal_fxaa_semantic
          PROPERTIES
            LABELS "metal;gpu;shader-artifact;semantic;opengl-oracle"
            TIMEOUT 120
          )
      endif ()
    endif ()
  endif ()
endif ()
