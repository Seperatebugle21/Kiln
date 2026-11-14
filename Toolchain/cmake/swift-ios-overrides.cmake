# Included right after Swift's project() call (CMAKE_PROJECT_INCLUDE).
#
# libSwiftScan depends on the `clang` executable target, which Kiln's iOS build of Clang leaves out
# (only its libraries are built). Kiln does not use libSwiftScan, so an empty target is enough
# to let CMake generate the build.
if(NOT TARGET clang)
  add_custom_target(clang)
endif()
