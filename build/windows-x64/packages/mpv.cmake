if("$ENV{MPV_COMMIT}" STREQUAL "")
  message(FATAL_ERROR "MPV_COMMIT is required")
endif()

ExternalProject_Add(
  mpv
  DEPENDS curl
          librempeg
          fribidi
          lcms2
          libass
          libiconv
          libjpeg
          libplacebo
          libpng
          sdl2
          luajit
          openal
          rubberband
          shaderc
          spirv-cross
          uchardet
          vulkan-loader
          winrt-headers
  GIT_REPOSITORY $ENV{MPV_REPOSITORY}
  GIT_TAG $ENV{MPV_COMMIT}
  UPDATE_COMMAND ""
  CONFIGURE_COMMAND
    ${EXEC} meson setup --reconfigure <BINARY_DIR> <SOURCE_DIR>
    --prefix=${MINGW_INSTALL_PREFIX}
    --libdir=${MINGW_INSTALL_PREFIX}/lib
    --cross-file=${MESON_CROSS}
    --buildtype=plain
    --default-library=shared
    --prefer-static
    -Db_lto_mode=thin
    -Db_ndebug=true
    -Dcplayer=false
    -Dd3d11=enabled
    -Diconv=enabled
    -Djavascript=disabled
    -Djpeg=enabled
    -Dlcms2=enabled
    -Dlibcurl=enabled
    -Dlibmpv=true
    -Dlua=enabled
    -Dmanpage-build=disabled
    -Dopenal=enabled
    -Drubberband=enabled
    -Dsdl2-audio=disabled
    -Dsdl2-gamepad=enabled
    -Dsdl2-video=disabled
    -Dshaderc=enabled
    -Dspirv-cross=enabled
    -Duchardet=enabled
    -Dvulkan=enabled
    -Dwin32-smtc=enabled
    -Dzimg=enabled
    -Dzlib=enabled
  BUILD_COMMAND ${NINJA} -C <BINARY_DIR>
  INSTALL_COMMAND ""
  LOG_DOWNLOAD 1
  LOG_UPDATE 1
  LOG_CONFIGURE 1
  LOG_BUILD 1
  LOG_INSTALL 1)

ExternalProject_Add_Step(
  mpv strip-library
  DEPENDEES build
  COMMAND ${EXEC} x86_64-w64-mingw32-strip -s <BINARY_DIR>/libmpv-2.dll)

ExternalProject_Add_Step(
  mpv copy-runtime
  DEPENDEES strip-library
  COMMAND ${CMAKE_COMMAND} -E make_directory
          ${CMAKE_CURRENT_BINARY_DIR}/mpv-runtime/licenses/mpv
  COMMAND ${CMAKE_COMMAND} -E make_directory
          ${CMAKE_CURRENT_BINARY_DIR}/mpv-runtime/licenses/librempeg
  COMMAND ${CMAKE_COMMAND} -E copy
          <BINARY_DIR>/libmpv-2.dll
          ${CMAKE_CURRENT_BINARY_DIR}/mpv-runtime/libmpv-2.dll
  COMMAND ${CMAKE_COMMAND} -E copy
          ${CMAKE_CURRENT_BINARY_DIR}/librempeg-package/ffmpeg.exe
          ${CMAKE_CURRENT_BINARY_DIR}/mpv-runtime/ffmpeg.exe
  COMMAND ${CMAKE_COMMAND} -E copy
          ${CMAKE_CURRENT_BINARY_DIR}/librempeg-package/ffprobe.exe
          ${CMAKE_CURRENT_BINARY_DIR}/mpv-runtime/ffprobe.exe
  COMMAND ${CMAKE_COMMAND} -E copy
          <SOURCE_DIR>/LICENSE.GPL
          ${CMAKE_CURRENT_BINARY_DIR}/mpv-runtime/licenses/mpv/LICENSE.GPL
  COMMAND ${CMAKE_COMMAND} -E copy
          <SOURCE_DIR>/LICENSE.LGPL
          ${CMAKE_CURRENT_BINARY_DIR}/mpv-runtime/licenses/mpv/LICENSE.LGPL)

force_rebuild_git(mpv)
force_meson_configure(mpv)
