# -*- cmake -*-
#
# Compared to other libraries, compiling this one is a mess.  The
# reason is that we have several source files that have two different
# sets of behaviour, depending on whether they're intended to be part
# of the viewer or the map server.
#
# Unfortunately, the affected code is a rat's nest of #ifdefs, so it's
# easier to play compilation tricks than to actually fix the problem.

project(llwindow)

include(00-Common)
include(DragDrop)
include(LLCommon)
include(LLImage)
include(LLWindow)
include(UI)
include(ViewerMiscLibs)
include(GLM)

set(llwindow_SOURCE_FILES
    llcursortypes.cpp
    llkeyboard.cpp
    llkeyboardheadless.cpp
    llwindowheadless.cpp
    llwindowcallbacks.cpp
    llwindow.cpp
    )

set(llwindow_HEADER_FILES
    CMakeLists.txt

    llcursortypes.h
    llkeyboard.h
    llkeyboardheadless.h
    llwindowheadless.h
    llwindowcallbacks.h
    )

set(viewer_SOURCE_FILES
    llmousehandler.cpp
    )

set(viewer_HEADER_FILES
    llwindow.h
    llpreeditor.h
    llmousehandler.h
    )

set(llwindow_LINK_LIBRARIES
        llcommon
        llimage
        llmath
        llrender
        llfilesystem
        llxml
        ll::glm
        ll::glext
        ll::uilibraries
        ll::SDL
        )

option(FIRESTORM_BUILD_ACTIVE_METAL_VIEWER
       "Build firestorm-bin as the developer-only active Metal bootstrap" OFF)
if (FIRESTORM_BUILD_ACTIVE_METAL_VIEWER AND NOT DARWIN)
  message(FATAL_ERROR "The active Metal viewer requires macOS")
endif ()

if(LINUX)
  set(llwindow_LINK_LIBRARIES ${llwindow_LINK_LIBRARIES} ll::fontconfig)
endif()

# Libraries on which this library depends, needed for Linux builds
# Sort by high-level to low-level
if (LINUX)
  if (USE_SDL1)
    list(APPEND viewer_SOURCE_FILES
            llkeyboardsdl.cpp
            llwindowsdl.cpp
            )
    list(APPEND viewer_HEADER_FILES
            llkeyboardsdl.h
            llwindowsdl.h
            )
  else()
    list(APPEND viewer_SOURCE_FILES
            llkeyboardsdl2.cpp
            llwindowsdl2.cpp
            )
    list(APPEND viewer_HEADER_FILES
            llkeyboardsdl2.h
            llwindowsdl2.h
            )
  endif()
  if (BUILD_HEADLESS)
    set(llwindowheadless_LINK_LIBRARIES
        ${LLCOMMON_LIBRARIES}
        ${LLIMAGE_LIBRARIES}
        ${LLMATH_LIBRARIES}
        ${LLRENDER_HEADLESS_LIBRARIES}
        ${LLFILESYSTEM_LIBRARIES}
        ${LLWINDOW_HEADLESS_LIBRARIES}
        ${LLXML_LIBRARIES}
        fontconfig          # For FCInit and other FC* functions.
        )
  endif (BUILD_HEADLESS)

endif (LINUX)

if (DARWIN)
  list(APPEND llwindow_SOURCE_FILES
    llkeyboardmacosx.cpp
    llwindowmacosx.cpp
    llwindowmacosx-objc.mm
    llopenglview-objc.mm
    )
  list(APPEND llwindow_HEADER_FILES
    llkeyboardmacosx.h
    llwindowmacosx.h
    llwindowmacosx-objc.h
    llopenglview-objc.h
    llappdelegate-objc.h
    )

  # We use a bunch of deprecated system APIs.
  set_source_files_properties(
      llkeyboardmacosx.cpp
      llwindowmacosx.cpp
      PROPERTIES
      COMPILE_FLAGS "-fpascal-strings"
      )
endif (DARWIN)


if (WINDOWS)
  list(APPEND llwindow_SOURCE_FILES
       llwindowwin32.cpp
       lldxhardware.cpp
       llkeyboardwin32.cpp
       lldragdropwin32.cpp
       )
  list(APPEND llwindow_HEADER_FILES
       llwindowwin32.h
       lldxhardware.h
       llkeyboardwin32.h
       lldragdropwin32.h
       )
  list(APPEND llwindow_LINK_LIBRARIES
       comdlg32     # Common Dialogs for ChooseColor
       ole32
       dxgi
       d3d9
       )
endif (WINDOWS)

if (SOLARIS)
  list(APPEND llwindow_SOURCE_FILES
       llwindowsolaris.cpp
       )
  list(APPEND llwindow_HEADER_FILES
       llwindowsolaris.h
       )
endif (SOLARIS)

if (BUILD_HEADLESS)
  set(llwindowheadless_SOURCE_FILES
       llwindowmesaheadless.cpp
       llmousehandler.cpp
       )
  set(llwindowheadless_HEADER_FILES
       llwindowmesaheadless.h
       llmousehandler.h
    )
  add_library (llwindowheadless
    ${llwindow_SOURCE_FILES}
    ${llwindowheadless_SOURCE_FILES}
    )
  set_property(TARGET llwindowheadless
    PROPERTY COMPILE_DEFINITIONS LL_MESA=1 LL_MESA_HEADLESS=1
    )
  target_link_libraries (llwindowheadless ${llwindowheadless_LINK_LIBRARIES} dl)
endif (BUILD_HEADLESS)

if (llwindow_HEADER_FILES)
  list(APPEND llwindow_SOURCE_FILES ${llwindow_HEADER_FILES})
endif (llwindow_HEADER_FILES)

  list(APPEND viewer_SOURCE_FILES ${viewer_HEADER_FILES})

  add_library (llwindow
    ${llwindow_SOURCE_FILES}
    ${viewer_SOURCE_FILES}
    )

  target_link_libraries (llwindow ${llwindow_LINK_LIBRARIES})
  target_include_directories(llwindow INTERFACE ${CMAKE_CURRENT_SOURCE_DIR})

if (DARWIN)
  target_link_libraries(llwindow ${CARBON_LIBRARY})
  option(FIRESTORM_BUILD_METAL_BOOTSTRAP
         "Configure the developer-only Metal presentation bootstrap" OFF)
  if (FIRESTORM_BUILD_METAL_BOOTSTRAP OR FIRESTORM_BUILD_ACTIVE_METAL_VIEWER)
    add_subdirectory(metal)
  endif ()
  if (FIRESTORM_BUILD_ACTIVE_METAL_VIEWER)
    target_compile_definitions(llwindow PUBLIC LL_ACTIVE_METAL_VIEWER=1)
    target_sources(llwindow PRIVATE
      metal/llmetalbootstrap.h
      metal/llmetalbootstrap-objc.mm
      )
    set_source_files_properties(
      metal/llmetalbootstrap-objc.mm
      PROPERTIES
      COMPILE_FLAGS "-fobjc-arc"
      SKIP_PRECOMPILE_HEADERS TRUE
      )
    add_dependencies(llwindow firestorm_metal_bootstrap_shader_library)
    target_include_directories(llwindow PUBLIC
      "${CMAKE_CURRENT_SOURCE_DIR}/metal"
      )
    target_compile_options(llwindow PRIVATE
      "-mmacosx-version-min=${FIRESTORM_METAL_BOOTSTRAP_MIN_MACOS}"
      )
    set_target_properties(llwindow PROPERTIES
      OSX_ARCHITECTURES "arm64"
      XCODE_ATTRIBUTE_MACOSX_DEPLOYMENT_TARGET
          "${FIRESTORM_METAL_BOOTSTRAP_MIN_MACOS}"
      )
    target_link_libraries(llwindow
      "${FIRESTORM_APPKIT_FRAMEWORK}"
      "${FIRESTORM_METAL_FRAMEWORK}"
      "${FIRESTORM_QUARTZCORE_FRAMEWORK}"
      )

    # Make the generated resource available to the later newview target.
    set(FIRESTORM_ACTIVE_METAL_LIBRARY "${FIRESTORM_METAL_LIBRARY}"
        PARENT_SCOPE)
    set(FIRESTORM_ACTIVE_METAL_MIN_MACOS
        "${FIRESTORM_METAL_BOOTSTRAP_MIN_MACOS}" PARENT_SCOPE)
  endif ()
endif (DARWIN)
