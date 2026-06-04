#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage: scripts/build-sdk.sh [linux|windows|macos] <x86_64|aarch64>
       scripts/build-sdk.sh <x86_64|aarch64>   # backwards-compatible Linux form

Build a Vulkan SDK-style install tree under dist/custom-vulkan-sdk/<platform>-<arch>.
By default this builds the full component set.

Environment variables:
  COMPONENTS             Comma list, "minimal", or "all" (default: all)
  VULKAN_SDK_REF         Common SDK tag for SDK-aligned upstreams (default: current_vulkan_sdk_tag)
  VULKAN_HEADERS_REF     Optional override for KhronosGroup/Vulkan-Headers
  VULKAN_LOADER_REF      Optional override for KhronosGroup/Vulkan-Loader
  VULKAN_UTILITY_LIBRARIES_REF Optional override for KhronosGroup/Vulkan-Utility-Libraries
  VULKAN_TOOLS_REF       Optional override for KhronosGroup/Vulkan-Tools
  VULKAN_VALIDATION_LAYERS_REF Optional override for KhronosGroup/Vulkan-ValidationLayers
  VULKAN_EXTENSION_LAYER_REF Optional override for KhronosGroup/Vulkan-ExtensionLayer
  VULKAN_PROFILES_REF    Optional override for KhronosGroup/Vulkan-Profiles
  SPIRV_HEADERS_REF      Optional override for KhronosGroup/SPIRV-Headers
  SPIRV_TOOLS_REF        Optional override for KhronosGroup/SPIRV-Tools
  GLSLANG_REF            Optional override for KhronosGroup/glslang
  SHADERC_REF            Optional override for google/shaderc (default: current SDK config commit)
  SPIRV_CROSS_REF        Optional override for KhronosGroup/SPIRV-Cross
  SLANG_REF              Optional override for shader-slang/slang
  BUILD_SLANG            ON/OFF compatibility switch (default: ON)
  SLANG_LLVM_FLAVOR      Slang LLVM mode; DISABLE avoids extra binary downloads (default: DISABLE)
  SLANG_ENABLE_DXIL      ON/OFF for Slang DXIL support (default: OFF)
  SLANG_LIB_TYPE         Slang compiler library type: SHARED or STATIC (default: SHARED)
  ENABLE_WSI             Linux only: ON/OFF for XCB, Xlib, Xrandr and Wayland support (default: ON)
  PREFER_STATIC_LIBS     ON/OFF to prefer static component libraries where practical (default: ON)
  KEEP_BUILD_DIRS        ON/OFF to preserve per-component build directories after install (default: OFF)
  PYTHON                 Python interpreter to use for CMake codegen/dependency scripts (default: auto-detect python3/python)
  WINDOWS_CMAKE_C_COMPILER   Direct Clang C compiler for Windows builds (default: clang)
  WINDOWS_CMAKE_CXX_COMPILER Direct Clang C++ compiler for Windows builds (default: clang++)
  WINDOWS_CLANG_TARGET   MSVC ABI Clang target for Windows builds (default: inferred from arch)
  WORK_DIR               Build/source directory (default: .build)
  DIST_DIR               Output directory (default: dist)
  JOBS                   Parallel build jobs (default: nproc/sysctl/2)
USAGE
}

if [[ ${1:-} == "-h" || ${1:-} == "--help" ]]; then
  usage
  exit 0
fi

if [[ $# -eq 1 ]]; then
  platform=linux
  arch=$1
elif [[ $# -eq 2 ]]; then
  platform=$1
  arch=$2
else
  usage >&2
  exit 2
fi

case "$platform" in
  linux|Linux) platform=linux ;;
  windows|Windows|win32|Win32) platform=windows ;;
  macos|MacOS|darwin|Darwin) platform=macos ;;
  *) usage >&2; exit 2 ;;
esac

case "$arch" in
  x86_64|amd64|AMD64) arch=x86_64 ;;
  aarch64|arm64|ARM64) arch=aarch64 ;;
  *) usage >&2; exit 2 ;;
esac

root_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
work_dir=${WORK_DIR:-"$root_dir/.build"}
dist_dir=${DIST_DIR:-"$root_dir/dist"}
src_dir="$work_dir/src"
build_dir="$work_dir/build"
sdk_dir="$dist_dir/custom-vulkan-sdk"
common_prefix="$sdk_dir/common"
arch_prefix="$sdk_dir/$platform-$arch"

if command -v nproc >/dev/null 2>&1; then
  default_jobs=$(nproc)
elif command -v sysctl >/dev/null 2>&1; then
  default_jobs=$(sysctl -n hw.ncpu 2>/dev/null || echo 2)
else
  default_jobs=2
fi
jobs=${JOBS:-$default_jobs}

current_vulkan_sdk_tag=vulkan-sdk-1.4.350.0
current_shaderc_commit=2a6a038115f801b142b94b53382a932acdb0edfc

default_vulkan_sdk_ref=${VULKAN_SDK_REF:-$current_vulkan_sdk_tag}
headers_ref=${VULKAN_HEADERS_REF:-$default_vulkan_sdk_ref}
loader_ref=${VULKAN_LOADER_REF:-$default_vulkan_sdk_ref}
utility_ref=${VULKAN_UTILITY_LIBRARIES_REF:-$default_vulkan_sdk_ref}
tools_ref=${VULKAN_TOOLS_REF:-$default_vulkan_sdk_ref}
validation_ref=${VULKAN_VALIDATION_LAYERS_REF:-$default_vulkan_sdk_ref}
extension_ref=${VULKAN_EXTENSION_LAYER_REF:-$default_vulkan_sdk_ref}
profiles_ref=${VULKAN_PROFILES_REF:-$default_vulkan_sdk_ref}
spirv_headers_ref=${SPIRV_HEADERS_REF:-$default_vulkan_sdk_ref}
spirv_tools_ref=${SPIRV_TOOLS_REF:-$default_vulkan_sdk_ref}
glslang_ref=${GLSLANG_REF:-$default_vulkan_sdk_ref}
shaderc_ref=${SHADERC_REF:-$current_shaderc_commit}
spirv_cross_ref=${SPIRV_CROSS_REF:-$default_vulkan_sdk_ref}
slang_ref=${SLANG_REF:-$default_vulkan_sdk_ref}
build_slang=${BUILD_SLANG:-ON}
slang_llvm_flavor=${SLANG_LLVM_FLAVOR:-DISABLE}
slang_enable_dxil=${SLANG_ENABLE_DXIL:-OFF}
slang_lib_type=${SLANG_LIB_TYPE:-SHARED}
enable_wsi=${ENABLE_WSI:-ON}
prefer_static_libs=${PREFER_STATIC_LIBS:-ON}
keep_build_dirs=${KEEP_BUILD_DIRS:-OFF}
windows_c_compiler=${WINDOWS_CMAKE_C_COMPILER:-clang}
windows_cxx_compiler=${WINDOWS_CMAKE_CXX_COMPILER:-clang++}
windows_clang_target=${WINDOWS_CLANG_TARGET:-}
if [[ -z "$windows_clang_target" ]]; then
  case "$arch" in
    x86_64) windows_clang_target=x86_64-pc-windows-msvc ;;
    aarch64) windows_clang_target=aarch64-pc-windows-msvc ;;
  esac
fi

host_arch=$(uname -m)
case "$host_arch" in
  arm64) host_arch=aarch64 ;;
  amd64|AMD64) host_arch=x86_64 ;;
esac
host_os=$(uname -s)

if [[ "$host_os" == Darwin* ]]; then
  # Homebrew Python's pyexpat extension may otherwise bind to macOS' older
  # /usr/lib/libexpat.1.dylib under self-hosted runners, causing XML codegen
  # scripts in SPIRV-Tools/Vulkan-Profiles to fail at build time.
  for expat_prefix in /opt/homebrew/opt/expat /usr/local/opt/expat; do
    if [[ -d "$expat_prefix/lib" ]]; then
      export DYLD_LIBRARY_PATH="$expat_prefix/lib${DYLD_LIBRARY_PATH:+:$DYLD_LIBRARY_PATH}"
      export DYLD_FALLBACK_LIBRARY_PATH="$expat_prefix/lib${DYLD_FALLBACK_LIBRARY_PATH:+:$DYLD_FALLBACK_LIBRARY_PATH}"
      break
    fi
  done
fi

find_python() {
  local candidates=()
  if [[ -n "${PYTHON:-}" ]]; then
    candidates+=("$PYTHON")
  fi
  candidates+=(python3 python)

  local candidate
  for candidate in "${candidates[@]}"; do
    if ! command -v "$candidate" >/dev/null 2>&1; then
      continue
    fi
    if "$candidate" - <<'PY' >/dev/null 2>&1
import json
import pathlib
import xml.etree.ElementTree as ET
ET.fromstring('<root><child /></root>')
PY
    then
      command -v "$candidate"
      return 0
    fi
  done

  echo "Could not find a usable Python interpreter. Install python3 or python with json/pathlib/xml.etree.ElementTree support, or set PYTHON=/path/to/python." >&2
  return 2
}

python_cmd=$(find_python)

normalize_bool() {
  local name=$1
  local value=$2
  case "$value" in
    ON|On|on|TRUE|True|true|1|YES|Yes|yes) echo ON ;;
    OFF|Off|off|FALSE|False|false|0|NO|No|no) echo OFF ;;
    *) echo "$name must be ON or OFF, got: $value" >&2; return 2 ;;
  esac
}

normalize_slang_lib_type() {
  local value=$1
  case "$value" in
    SHARED|shared|Shared) echo SHARED ;;
    STATIC|static|Static) echo STATIC ;;
    *) echo "SLANG_LIB_TYPE must be SHARED or STATIC, got: $value" >&2; return 2 ;;
  esac
}

enable_wsi=$(normalize_bool ENABLE_WSI "$enable_wsi")
build_slang=$(normalize_bool BUILD_SLANG "$build_slang")
slang_enable_dxil=$(normalize_bool SLANG_ENABLE_DXIL "$slang_enable_dxil")
slang_lib_type=$(normalize_slang_lib_type "$slang_lib_type")
prefer_static_libs=$(normalize_bool PREFER_STATIC_LIBS "$prefer_static_libs")
keep_build_dirs=$(normalize_bool KEEP_BUILD_DIRS "$keep_build_dirs")

full_components="vulkan-headers,vulkan-loader,vulkan-utility-libraries,spirv-headers,spirv-tools,glslang,spirv-cross,shaderc,vulkan-tools,vulkan-validationlayers,vulkan-extensionlayer,vulkan-profiles,slang"
minimal_components="vulkan-headers,vulkan-loader,slang"
components=${COMPONENTS:-all}
case "$components" in
  all|ALL|All) components=$full_components ;;
  minimal|MINIMAL|Minimal) components=$minimal_components ;;
esac
if [[ "$build_slang" == OFF ]]; then
  components=$(printf '%s' "$components" | tr ',' '\n' | grep -vx 'slang' | paste -sd, - || true)
fi

has_component() {
  local component=$1
  printf ',%s,' "$components" | grep -q ",$component,"
}

mkdir -p "$src_dir" "$build_dir" "$common_prefix" "$arch_prefix"

clone_ref() {
  local repo_url=$1
  local ref=$2
  local dest=$3
  local recursive=${4:-no}

  if [[ -d "$dest/.git" ]]; then
    git -C "$dest" fetch origin "$ref" || true
    git -C "$dest" checkout "$ref" 2>/dev/null || git -C "$dest" checkout --detach FETCH_HEAD
    if [[ "$recursive" == yes ]]; then
      git -C "$dest" submodule update --init --recursive --depth 1
    fi
    return
  fi

  if [[ "$recursive" == yes ]]; then
    if ! git clone --recursive --depth 1 --branch "$ref" "$repo_url" "$dest"; then
      rm -rf "$dest"
      git clone --recursive "$repo_url" "$dest"
      git -C "$dest" checkout "$ref"
      git -C "$dest" submodule update --init --recursive
    fi
  else
    if ! git clone --depth 1 --branch "$ref" "$repo_url" "$dest"; then
      rm -rf "$dest"
      git clone "$repo_url" "$dest"
      git -C "$dest" checkout "$ref"
    fi
  fi
  git -C "$dest" fetch --tags --force origin || true
}

fetch_component_sources() {
  clone_ref https://github.com/KhronosGroup/Vulkan-Headers.git "$headers_ref" "$src_dir/Vulkan-Headers"
  has_component vulkan-loader && clone_ref https://github.com/KhronosGroup/Vulkan-Loader.git "$loader_ref" "$src_dir/Vulkan-Loader"
  has_component vulkan-utility-libraries && clone_ref https://github.com/KhronosGroup/Vulkan-Utility-Libraries.git "$utility_ref" "$src_dir/Vulkan-Utility-Libraries"
  has_component vulkan-tools && clone_ref https://github.com/KhronosGroup/Vulkan-Tools.git "$tools_ref" "$src_dir/Vulkan-Tools"
  has_component vulkan-validationlayers && clone_ref https://github.com/KhronosGroup/Vulkan-ValidationLayers.git "$validation_ref" "$src_dir/Vulkan-ValidationLayers"
  has_component vulkan-extensionlayer && clone_ref https://github.com/KhronosGroup/Vulkan-ExtensionLayer.git "$extension_ref" "$src_dir/Vulkan-ExtensionLayer"
  has_component vulkan-profiles && clone_ref https://github.com/KhronosGroup/Vulkan-Profiles.git "$profiles_ref" "$src_dir/Vulkan-Profiles"
  has_component spirv-headers && clone_ref https://github.com/KhronosGroup/SPIRV-Headers.git "$spirv_headers_ref" "$src_dir/SPIRV-Headers"
  has_component spirv-tools && clone_ref https://github.com/KhronosGroup/SPIRV-Tools.git "$spirv_tools_ref" "$src_dir/SPIRV-Tools"
  has_component glslang && clone_ref https://github.com/KhronosGroup/glslang.git "$glslang_ref" "$src_dir/glslang"
  has_component shaderc && clone_ref https://github.com/google/shaderc.git "$shaderc_ref" "$src_dir/shaderc"
  has_component spirv-cross && clone_ref https://github.com/KhronosGroup/SPIRV-Cross.git "$spirv_cross_ref" "$src_dir/SPIRV-Cross"
  has_component slang && clone_ref https://github.com/shader-slang/slang.git "$slang_ref" "$src_dir/slang" yes
  return 0
}

copy_common_files() {
  rm -rf "$arch_prefix/include" "$arch_prefix/share/vulkan/registry"
  mkdir -p "$arch_prefix/share/vulkan"
  cp -a "$common_prefix/include" "$arch_prefix/include"
  if [[ -d "$common_prefix/share/vulkan/registry" ]]; then
    cp -a "$common_prefix/share/vulkan/registry" "$arch_prefix/share/vulkan/registry"
  fi
}

component_commit() {
  local dir=$1
  if [[ -d "$src_dir/$dir/.git" ]]; then
    git -C "$src_dir/$dir" rev-parse HEAD
  else
    echo "not built"
  fi
}

write_component_manifest() {
  cat > "$arch_prefix/BUILD-MANIFEST.md" <<EOF
# SDK Components: $platform-$arch

| Component | Upstream | Requested ref | Resolved commit | Included output |
| --- | --- | --- | --- | --- |
| Vulkan Headers | https://github.com/KhronosGroup/Vulkan-Headers | $headers_ref | $(component_commit Vulkan-Headers) | headers and registry |
| Vulkan Loader | https://github.com/KhronosGroup/Vulkan-Loader | $loader_ref | $(component_commit Vulkan-Loader) | platform Vulkan loader |
| Vulkan Utility Libraries | https://github.com/KhronosGroup/Vulkan-Utility-Libraries | $utility_ref | $(component_commit Vulkan-Utility-Libraries) | helper libraries used by Vulkan tools/layers |
| SPIRV-Headers | https://github.com/KhronosGroup/SPIRV-Headers | $spirv_headers_ref | $(component_commit SPIRV-Headers) | SPIR-V headers |
| SPIRV-Tools | https://github.com/KhronosGroup/SPIRV-Tools | $spirv_tools_ref | $(component_commit SPIRV-Tools) | spirv-as, spirv-dis, spirv-val, spirv-opt, etc. |
| glslang | https://github.com/KhronosGroup/glslang | $glslang_ref | $(component_commit glslang) | glslangValidator |
| SPIRV-Cross | https://github.com/KhronosGroup/SPIRV-Cross | $spirv_cross_ref | $(component_commit SPIRV-Cross) | spirv-cross |
| shaderc | https://github.com/google/shaderc | $shaderc_ref | $(component_commit shaderc) | glslc and shaderc libraries |
| Vulkan Tools | https://github.com/KhronosGroup/Vulkan-Tools | $tools_ref | $(component_commit Vulkan-Tools) | vulkaninfo and demos/tools |
| Vulkan ValidationLayers | https://github.com/KhronosGroup/Vulkan-ValidationLayers | $validation_ref | $(component_commit Vulkan-ValidationLayers) | validation layer binaries and JSON manifests |
| Vulkan ExtensionLayer | https://github.com/KhronosGroup/Vulkan-ExtensionLayer | $extension_ref | $(component_commit Vulkan-ExtensionLayer) | extension/emulation layer binaries and JSON manifests |
| Vulkan Profiles | https://github.com/KhronosGroup/Vulkan-Profiles | $profiles_ref | $(component_commit Vulkan-Profiles) | Vulkan profiles library/tooling/data |
| Slang | https://github.com/shader-slang/slang | $slang_ref | $(component_commit slang) | slangc, headers, libraries |

## Build options

| Option | Value |
| --- | --- |
| Platform | $platform |
| Architecture | $arch |
| COMPONENTS | $components |
| BUILD_SLANG | $build_slang |
| SLANG_LLVM_FLAVOR | $slang_llvm_flavor |
| SLANG_ENABLE_DXIL | $slang_enable_dxil |
| SLANG_LIB_TYPE | $slang_lib_type |
| ENABLE_WSI | $enable_wsi |
| PREFER_STATIC_LIBS | $prefer_static_libs |
| KEEP_BUILD_DIRS | $keep_build_dirs |

This package does not include a GPU driver/ICD.
EOF
}

write_setup_env_sh() {
  cat > "$sdk_dir/setup-env.sh" <<'EOF'
#!/usr/bin/env bash
# Source this file: source /path/to/custom-vulkan-sdk/setup-env.sh

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  echo "This script must be sourced, not executed." >&2
  exit 1
fi

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
case "$(uname -s)" in
  Linux*) PLATFORM=linux ;;
  Darwin*) PLATFORM=macos ;;
  MINGW*|MSYS*|CYGWIN*) PLATFORM=windows ;;
  *) echo "Unsupported OS: $(uname -s)" >&2; return 1 ;;
esac
case "$(uname -m)" in
  x86_64|amd64) ARCH=x86_64 ;;
  aarch64|arm64) ARCH=aarch64 ;;
  *) echo "Unsupported machine architecture: $(uname -m)" >&2; return 1 ;;
esac

export VULKAN_SDK="$ROOT/$PLATFORM-$ARCH"
export PATH="$VULKAN_SDK/bin:${PATH:-}"
export CPATH="$VULKAN_SDK/include:${CPATH:-}"
export CMAKE_PREFIX_PATH="$VULKAN_SDK:${CMAKE_PREFIX_PATH:-}"
export PKG_CONFIG_PATH="$VULKAN_SDK/lib/pkgconfig:${PKG_CONFIG_PATH:-}"

case "$PLATFORM" in
  linux) export LD_LIBRARY_PATH="$VULKAN_SDK/lib:${LD_LIBRARY_PATH:-}" ;;
  macos) export DYLD_LIBRARY_PATH="$VULKAN_SDK/lib:${DYLD_LIBRARY_PATH:-}" ;;
esac
EOF
  chmod +x "$sdk_dir/setup-env.sh"
}

write_setup_env_ps1() {
  cat > "$sdk_dir/setup-env.ps1" <<'EOF'
# Source this file from PowerShell:
#   . .\custom-vulkan-sdk\setup-env.ps1

$Root = Split-Path -Parent $MyInvocation.MyCommand.Path
$Machine = $env:PROCESSOR_ARCHITECTURE
switch -Regex ($Machine) {
  '^(AMD64|x86_64)$' { $Arch = 'x86_64'; break }
  '^(ARM64|aarch64)$' { $Arch = 'aarch64'; break }
  default { throw "Unsupported machine architecture: $Machine" }
}

$env:VULKAN_SDK = Join-Path $Root "windows-$Arch"
$env:Path = (Join-Path $env:VULKAN_SDK 'bin') + [IO.Path]::PathSeparator + $env:Path
$env:CPATH = (Join-Path $env:VULKAN_SDK 'include') + [IO.Path]::PathSeparator + $env:CPATH
$env:CMAKE_PREFIX_PATH = $env:VULKAN_SDK + [IO.Path]::PathSeparator + $env:CMAKE_PREFIX_PATH
EOF
}

cmake_generator_args=(-G Ninja)
cmake_configure_type_args=(-DCMAKE_BUILD_TYPE=Release)

cmake_build_install() {
  local build=$1
  cmake --build "$build" --target install --parallel "$jobs"
  if [[ "$keep_build_dirs" == OFF ]]; then
    rm -rf "$build"
  fi
}

cmake_configure() {
  local source=$1
  local build=$2
  local install_prefix=$3
  local prefix_path=$4
  shift 4

  local args=(
    cmake
    -S "$source"
    -B "$build"
    "${cmake_generator_args[@]}"
    "${cmake_configure_type_args[@]}"
    -DCMAKE_INSTALL_PREFIX="$install_prefix"
    -DPython3_EXECUTABLE="$python_cmd"
  )

  if [[ "$platform" != windows ]]; then
    args+=(-DCMAKE_POSITION_INDEPENDENT_CODE=ON)
  fi

  if [[ -n "$prefix_path" ]]; then
    args+=(-DCMAKE_PREFIX_PATH="$prefix_path")
  fi
  if [[ "$prefer_static_libs" == ON ]]; then
    args+=(-DBUILD_SHARED_LIBS=OFF)
  fi
  if [[ "$platform" == windows ]]; then
    # Direct clang with an MSVC target predefines _WIN32, but not WIN32.  Some
    # Vulkan SDK components still gate Windows-only code on WIN32.  Keep the
    # normal Windows macros while also blocking Windows SDK min/max macros and
    # CRT deprecation warnings from breaking GNU-like clang command-line builds.
    local windows_c_flags="${CFLAGS:-}"
    local windows_cxx_flags="${CXXFLAGS:-}"
    local windows_compat_defines="-DWIN32 -D_WINDOWS -DNOMINMAX -DWIN32_LEAN_AND_MEAN -D_CRT_SECURE_NO_WARNINGS"
    windows_c_flags="${windows_c_flags:+$windows_c_flags }$windows_compat_defines"
    windows_cxx_flags="${windows_cxx_flags:+$windows_cxx_flags }$windows_compat_defines"
    args+=(
      -DCMAKE_C_COMPILER="$windows_c_compiler"
      -DCMAKE_CXX_COMPILER="$windows_cxx_compiler"
      -DCMAKE_C_COMPILER_TARGET="$windows_clang_target"
      -DCMAKE_CXX_COMPILER_TARGET="$windows_clang_target"
      -DCMAKE_C_FLAGS="$windows_c_flags"
      -DCMAKE_CXX_FLAGS="$windows_cxx_flags"
    )
    if command -v llvm-rc >/dev/null 2>&1; then
      args+=(-DCMAKE_RC_COMPILER="$(command -v llvm-rc)")
    fi
    if command -v llvm-mt >/dev/null 2>&1; then
      args+=(-DCMAKE_MT="$(command -v llvm-mt)")
    fi
  fi

  args+=("$@")
  "${args[@]}"
}

require_direct_clang() {
  local compiler=$1
  local label=$2
  local compiler_base
  compiler_base=$(basename "$compiler" | tr '[:upper:]' '[:lower:]')
  case "$compiler_base" in
    clang-cl|clang-cl.exe)
      echo "$label must be the direct clang driver, not clang-cl: $compiler" >&2
      exit 2
      ;;
  esac
  if ! command -v "$compiler" >/dev/null 2>&1; then
    echo "$label not found on PATH: $compiler" >&2
    exit 2
  fi
}

require_windows_msvc_clang() {
  local compiler=$1
  local label=$2
  local target
  target=$("$compiler" --target="$windows_clang_target" -dumpmachine 2>/dev/null || "$compiler" --target="$windows_clang_target" --print-target-triple 2>/dev/null || true)
  case "$target" in
    *windows-msvc*) ;;
    *windows-gnu*|*w64-windows-gnu*)
      echo "$label targets GNU/MinGW ($target). Use direct Clang with the MSVC ABI target, not the GNU Windows target." >&2
      exit 2
      ;;
    *)
      echo "$label must target the Windows MSVC ABI for this Windows build, got: ${target:-unknown}" >&2
      exit 2
      ;;
  esac
}

check_native_platform() {
  if [[ "$platform" == "linux" ]]; then
    if [[ "$arch" == "aarch64" && "$host_arch" != "aarch64" ]]; then
      echo "==> Cross-compiling linux-aarch64 from $host_arch"
      export PKG_CONFIG_LIBDIR="/usr/lib/aarch64-linux-gnu/pkgconfig:/usr/share/pkgconfig"
      export PKG_CONFIG_PATH=""
      export PKG_CONFIG_SYSROOT_DIR=""
    elif [[ "$arch" != "$host_arch" ]]; then
      echo "Cannot build linux-$arch on host architecture $host_arch without a toolchain." >&2
      exit 2
    else
      echo "==> Native Linux build on $host_arch"
    fi
  elif [[ "$platform" == "macos" ]]; then
    if [[ "$host_os" != Darwin* ]]; then
      echo "Cannot build macos-$arch on non-macOS host $host_os." >&2
      exit 2
    fi
    if [[ "$arch" != "$host_arch" ]]; then
      echo "Cannot build macos-$arch on host architecture $host_arch with this script." >&2
      exit 2
    fi
    echo "==> Native macOS build on $host_arch"
  elif [[ "$platform" == "windows" ]]; then
    case "$host_os" in
      MINGW*|MSYS*|CYGWIN*) ;;
      *) echo "Cannot build windows-$arch on non-Windows host $host_os." >&2; exit 2 ;;
    esac
    require_direct_clang "$windows_c_compiler" WINDOWS_CMAKE_C_COMPILER
    require_direct_clang "$windows_cxx_compiler" WINDOWS_CMAKE_CXX_COMPILER
    require_windows_msvc_clang "$windows_c_compiler" WINDOWS_CMAKE_C_COMPILER
    require_windows_msvc_clang "$windows_cxx_compiler" WINDOWS_CMAKE_CXX_COMPILER
    if ! command -v llvm-rc >/dev/null 2>&1; then
      echo "llvm-rc is required for Windows resource compilation when building with direct clang." >&2
      exit 2
    fi
    echo "==> Native Windows build requested for $arch using $windows_c_compiler/$windows_cxx_compiler --target=$windows_clang_target"
  fi
}

cmake_install() {
  local name=$1
  local source=$2
  local build=$3
  shift 3

  echo "==> Building $name"
  cmake_configure "$source" "$build" "$arch_prefix" "$arch_prefix;$common_prefix" "$@"
  cmake_build_install "$build"
}

cmake_install_common() {
  local name=$1
  local source=$2
  local build=$3
  shift 3

  echo "==> Building $name"
  cmake_configure "$source" "$build" "$common_prefix" "" "$@"
  cmake_build_install "$build"
}

build_headers() {
  cmake_install_common Vulkan-Headers "$src_dir/Vulkan-Headers" "$build_dir/headers-$platform-$arch"
  copy_common_files
}

build_loader() {
  local extra=(
    -DVULKAN_HEADERS_INSTALL_DIR="$common_prefix"
    -DBUILD_TESTS=OFF
  )
  if [[ "$platform" == linux ]]; then
    extra+=(
      -DBUILD_WSI_XCB_SUPPORT="$enable_wsi"
      -DBUILD_WSI_XLIB_SUPPORT="$enable_wsi"
      -DBUILD_WSI_XLIB_XRANDR_SUPPORT="$enable_wsi"
      -DBUILD_WSI_WAYLAND_SUPPORT="$enable_wsi"
      -DBUILD_WSI_DIRECTFB_SUPPORT=OFF
    )
    if [[ "$arch" == "aarch64" && "$host_arch" != "aarch64" ]]; then
      extra+=(-DCMAKE_TOOLCHAIN_FILE="$root_dir/cmake/toolchains/aarch64-linux-gnu.cmake")
    fi
  fi
  cmake_install Vulkan-Loader "$src_dir/Vulkan-Loader" "$build_dir/loader-$platform-$arch" "${extra[@]}"
}

build_utility_libraries() {
  cmake_install Vulkan-Utility-Libraries "$src_dir/Vulkan-Utility-Libraries" "$build_dir/utility-$platform-$arch" \
    -DVULKAN_HEADERS_INSTALL_DIR="$common_prefix" \
    -DBUILD_TESTS=OFF
}

build_spirv_headers() {
  cmake_install SPIRV-Headers "$src_dir/SPIRV-Headers" "$build_dir/spirv-headers-$platform-$arch"
}

build_spirv_tools() {
  cmake_install SPIRV-Tools "$src_dir/SPIRV-Tools" "$build_dir/spirv-tools-$platform-$arch" \
    -DSPIRV-Headers_SOURCE_DIR="$src_dir/SPIRV-Headers" \
    -DSPIRV_TOOLS_BUILD_STATIC=ON \
    -DSPIRV_SKIP_TESTS=ON \
    -DSPIRV_WERROR=OFF
}

build_glslang() {
  cmake_install glslang "$src_dir/glslang" "$build_dir/glslang-$platform-$arch" \
    -DBUILD_TESTING=OFF \
    -DGLSLANG_TESTS=OFF \
    -DENABLE_GLSLANG_BINARIES=ON \
    -DENABLE_HLSL=ON \
    -DENABLE_OPT=OFF
}

build_spirv_cross() {
  cmake_install SPIRV-Cross "$src_dir/SPIRV-Cross" "$build_dir/spirv-cross-$platform-$arch" \
    -DSPIRV_CROSS_CLI=ON \
    -DSPIRV_CROSS_STATIC=ON \
    -DSPIRV_CROSS_SHARED=OFF \
    -DSPIRV_CROSS_ENABLE_TESTS=OFF
}

build_shaderc() {
  local shaderc_source="$src_dir/shaderc"

  # The Vulkan SDK-pinned shaderc checkout is a small dependency-sync wrapper:
  # update_shaderc_sources.py creates the actual shaderc CMake source tree in
  # ./src, matching LunarG's SDK config for shaderc.
  if [[ -f "$shaderc_source/update_shaderc_sources.py" ]]; then
    (cd "$shaderc_source" && "$python_cmd" update_shaderc_sources.py)
    shaderc_source="$shaderc_source/src"
  elif [[ -f "$shaderc_source/utils/git-sync-deps" ]]; then
    (cd "$shaderc_source" && "$python_cmd" utils/git-sync-deps)
  fi

  cmake_install shaderc "$shaderc_source" "$build_dir/shaderc-$platform-$arch" \
    -DSHADERC_SKIP_TESTS=ON \
    -DSHADERC_SKIP_EXAMPLES=ON \
    -DSHADERC_ENABLE_WERROR_COMPILE=OFF
}

patch_extension_layer_for_windows_clang() {
  if [[ "$platform" != windows ]]; then
    return 0
  fi

  local cmake_file="$src_dir/Vulkan-ExtensionLayer/layers/CMakeLists.txt"
  "$python_cmd" - "$cmake_file" <<'PY'
from pathlib import Path
import sys

cmake_file = Path(sys.argv[1])
text = cmake_file.read_text()
old = """    if(MSVC)
        target_link_options(${extension_layer} PRIVATE /DEF:${CMAKE_CURRENT_SOURCE_DIR}/${extension_layer}.def)
        target_compile_definitions(${extension_layer} PUBLIC NOMINMAX)
    elseif(MINGW)
        target_sources(${extension_layer} PRIVATE ${extension_layer}.def)
    elseif(APPLE)
"""
new = """    if(MSVC)
        target_link_options(${extension_layer} PRIVATE /DEF:${CMAKE_CURRENT_SOURCE_DIR}/${extension_layer}.def)
        target_compile_definitions(${extension_layer} PUBLIC NOMINMAX)
    elseif(MINGW)
        target_sources(${extension_layer} PRIVATE ${extension_layer}.def)
    elseif(WIN32)
        target_link_options(${extension_layer} PRIVATE LINKER:/DEF:${CMAKE_CURRENT_SOURCE_DIR}/${extension_layer}.def)
        target_compile_definitions(${extension_layer} PUBLIC NOMINMAX)
    elseif(APPLE)
"""
if new in text:
    sys.exit(0)
if old not in text:
    raise SystemExit(f"Could not patch Windows direct-Clang link options in {cmake_file}")
cmake_file.write_text(text.replace(old, new, 1))
PY
}

patch_validation_layers_for_windows_clang() {
  if [[ "$platform" != windows ]]; then
    return 0
  fi

  if [[ "$arch" == aarch64 ]]; then
    # ValidationLayers' Windows dependency updater builds mimalloc by default.
    # mimalloc 3.3.2 currently fails with direct Clang/MSVC-ABI ARM64 builds due
    # to undeclared MSVC ARM64 acquire/release intrinsics (__ldar64/__stlr64).
    # mimalloc is an optional performance allocator for VVL, so skip it only for
    # Windows ARM64 and let VVL fall back to the CRT allocator.
    local known_good="$src_dir/Vulkan-ValidationLayers/scripts/known_good.json"
    "$python_cmd" - "$known_good" <<'PY'
import json
from pathlib import Path
import sys

known_good = Path(sys.argv[1])
data = json.loads(known_good.read_text())
for repo in data.get("repos", []):
    if repo.get("name") == "mimalloc":
        repo["build_architectures"] = ["64", "x64", "win64"]
        break
else:
    raise SystemExit(f"Could not find mimalloc entry in {known_good}")
known_good.write_text(json.dumps(data, indent=4) + "\n")
PY
  fi
}

patch_vulkan_profiles_for_windows_clang() {
  if [[ "$platform" != windows ]]; then
    return 0
  fi

  local cmake_file="$src_dir/Vulkan-Profiles/layer/CMakeLists.txt"
  "$python_cmd" - "$cmake_file" <<'PY'
from pathlib import Path
import sys

cmake_file = Path(sys.argv[1])
text = cmake_file.read_text()
old = """elseif(MINGW)
    target_sources(ProfilesLayer PRIVATE ${LAYER_NAME}.def)
elseif(APPLE)
"""
new = """elseif(MINGW)
    target_sources(ProfilesLayer PRIVATE ${LAYER_NAME}.def)
elseif(WIN32)
    message(DEBUG "Functions are exported via ${LAYER_NAME}.def")
elseif(APPLE)
"""
if new in text:
    sys.exit(0)
if old not in text:
    raise SystemExit(f"Could not patch Windows direct-Clang link options in {cmake_file}")
cmake_file.write_text(text.replace(old, new, 1))
PY
}

build_vulkan_tools() {
  cmake_install Vulkan-Tools "$src_dir/Vulkan-Tools" "$build_dir/vulkan-tools-$platform-$arch" \
    -DUPDATE_DEPS=ON \
    -DBUILD_TESTS=OFF \
    -DVULKAN_HEADERS_INSTALL_DIR="$common_prefix" \
    -DVULKAN_LOADER_INSTALL_DIR="$arch_prefix" \
    -DVULKAN_UTILITY_LIBRARIES_INSTALL_DIR="$arch_prefix"
}

build_validation_layers() {
  patch_validation_layers_for_windows_clang

  local extra=(
    -DUPDATE_DEPS=ON
    -DBUILD_TESTS=OFF
    -DVULKAN_HEADERS_INSTALL_DIR="$common_prefix"
    -DVULKAN_UTILITY_LIBRARIES_INSTALL_DIR="$arch_prefix"
    -DSPIRV_HEADERS_INSTALL_DIR="$arch_prefix"
    -DSPIRV_TOOLS_INSTALL_DIR="$arch_prefix"
    -DGLSLANG_INSTALL_DIR="$arch_prefix"
  )
  if [[ "$platform" == windows && "$arch" == aarch64 ]]; then
    extra+=(-DUSE_MIMALLOC=OFF)
  fi

  cmake_install Vulkan-ValidationLayers "$src_dir/Vulkan-ValidationLayers" "$build_dir/validation-$platform-$arch" "${extra[@]}"
}

build_extension_layer() {
  # Vulkan-ExtensionLayer 1.4.350 treats GNU-style clang as non-MSVC even when
  # targeting the Windows MSVC ABI, which otherwise feeds ELF options such as
  # --version-script and -Bsymbolic to lld-link/link.exe.
  patch_extension_layer_for_windows_clang

  cmake_install Vulkan-ExtensionLayer "$src_dir/Vulkan-ExtensionLayer" "$build_dir/extension-layer-$platform-$arch" \
    -DUPDATE_DEPS=ON \
    -DBUILD_TESTS=OFF \
    -DVULKAN_HEADERS_INSTALL_DIR="$common_prefix" \
    -DVULKAN_UTILITY_LIBRARIES_INSTALL_DIR="$arch_prefix"
}

build_vulkan_profiles() {
  # Vulkan-Profiles 1.4.350 also keys Windows linker handling off MSVC.  With
  # direct clang targeting the MSVC ABI, WIN32 is true but MSVC is false, so
  # avoid the Unix/ELF version-script/-Bsymbolic fallback on Windows.
  patch_vulkan_profiles_for_windows_clang

  cmake_install Vulkan-Profiles "$src_dir/Vulkan-Profiles" "$build_dir/profiles-$platform-$arch" \
    -DUPDATE_DEPS=ON \
    -DBUILD_TESTS=OFF \
    -DVULKAN_HEADERS_INSTALL_DIR="$common_prefix"
}

build_slang_component() {
  local extra=(
    -DSLANG_USE_SYSTEM_VULKAN_HEADERS=OFF
    -DSLANG_USE_SYSTEM_GLSLANG=OFF
  )

  # On Linux, reuse SDK SPIR-V components that were already built instead of
  # compiling Slang's bundled copies. This keeps full SDK builds within the disk
  # budget on smaller self-hosted runners. Keep Windows on Slang's bundled
  # deps: CMake package discovery from MSYS paths is less reliable there, and
  # Vulkan-Headers may not be found even when the SDK prefix was installed.
  if [[ "$platform" == linux ]]; then
    if has_component spirv-headers; then
      extra+=(-DSLANG_USE_SYSTEM_SPIRV_HEADERS=ON)
    else
      extra+=(-DSLANG_USE_SYSTEM_SPIRV_HEADERS=OFF)
    fi
    if has_component spirv-tools; then
      extra+=(-DSLANG_USE_SYSTEM_SPIRV_TOOLS=ON)
    else
      extra+=(-DSLANG_USE_SYSTEM_SPIRV_TOOLS=OFF)
    fi
  else
    extra+=(
      -DSLANG_USE_SYSTEM_SPIRV_HEADERS=OFF
      -DSLANG_USE_SYSTEM_SPIRV_TOOLS=OFF
    )
  fi
  cmake_install Slang "$src_dir/slang" "$build_dir/slang-$platform-$arch" \
    -DSLANG_ENABLE_SLANGC=ON \
    -DSLANG_ENABLE_SLANGD=ON \
    -DSLANG_ENABLE_SLANGI=ON \
    -DSLANG_ENABLE_SLANGRT=ON \
    -DSLANG_ENABLE_TESTS=OFF \
    -DSLANG_ENABLE_EXAMPLES=OFF \
    -DSLANG_ENABLE_GFX=OFF \
    -DSLANG_ENABLE_SLANG_RHI=OFF \
    -DSLANG_ENABLE_REPLAYER=OFF \
    -DSLANG_EXCLUDE_DAWN=ON \
    -DSLANG_EXCLUDE_TINT=ON \
    -DSLANG_ENABLE_DXIL="$slang_enable_dxil" \
    -DSLANG_SLANG_LLVM_FLAVOR="$slang_llvm_flavor" \
    -DSLANG_ENABLE_PCH=OFF \
    -DSLANG_ENABLE_RELEASE_DEBUG_INFO=OFF \
    -DSLANG_ENABLE_RELEASE_LTO=OFF \
    -DSLANG_LIB_TYPE="$slang_lib_type" \
    "${extra[@]}"
}

check_native_platform

echo "==> Components: $components"
echo "==> Fetching component sources"
fetch_component_sources

write_setup_env_sh
write_setup_env_ps1

build_headers
has_component vulkan-utility-libraries && build_utility_libraries
has_component vulkan-loader && build_loader
has_component spirv-headers && build_spirv_headers
has_component spirv-tools && build_spirv_tools
has_component glslang && build_glslang
has_component spirv-cross && build_spirv_cross
has_component shaderc && build_shaderc
has_component vulkan-tools && build_vulkan_tools
has_component vulkan-validationlayers && build_validation_layers
has_component vulkan-extensionlayer && build_extension_layer
has_component vulkan-profiles && build_vulkan_profiles
has_component slang && build_slang_component

write_component_manifest

echo "==> Installed $platform-$arch files under $arch_prefix"
find "$arch_prefix" -maxdepth 3 -type f | sort
