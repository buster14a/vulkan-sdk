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
  WINDOWS_CMAKE_C_COMPILER   MSVC C compiler for Windows builds (default: cl)
  WINDOWS_CMAKE_CXX_COMPILER MSVC C++ compiler for Windows builds (default: cl)
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
windows_c_compiler=${WINDOWS_CMAKE_C_COMPILER:-cl}
windows_cxx_compiler=${WINDOWS_CMAKE_CXX_COMPILER:-cl}
windows_linker=
windows_lib=
windows_rc=
windows_mt=
windows_dumpbin=

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

reset_stale_windows_cmake_cache() {
  local build=$1
  local cache="$build/CMakeCache.txt"
  [[ "$platform" == windows && -f "$cache" ]] || return 0

  if grep -Eiq '^CMAKE_(C|CXX)_COMPILER:[^=]*=.*(clang|gcc|g\+\+)' "$cache"; then
    echo "==> Removing stale non-MSVC Windows CMake build directory: $build"
    rm -rf "$build"
  fi
}

cmake_configure() {
  local source=$1
  local build=$2
  local install_prefix=$3
  local prefix_path=$4
  shift 4

  reset_stale_windows_cmake_cache "$build"

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
    # Use the MSVC toolchain from a Visual Studio Developer environment.  Slang
    # also runs dumpbin at build time to generate its proxy DLL exports, so the
    # MSVC tools must be on PATH before configuration starts.
    local windows_c_flags="${CFLAGS:-}"
    local windows_cxx_flags="${CXXFLAGS:-}"
    local windows_compat_defines="-DWIN32 -D_WINDOWS -DNOMINMAX -DWIN32_LEAN_AND_MEAN -D_CRT_SECURE_NO_WARNINGS"
    windows_c_flags="${windows_c_flags:+$windows_c_flags }$windows_compat_defines"
    windows_cxx_flags="${windows_cxx_flags:+$windows_cxx_flags }$windows_compat_defines /EHsc"
    args+=(
      -DCMAKE_C_COMPILER="$windows_c_compiler"
      -DCMAKE_CXX_COMPILER="$windows_cxx_compiler"
      -DCMAKE_LINKER="$windows_linker"
      -DCMAKE_AR="$windows_lib"
      -DCMAKE_RC_COMPILER="$windows_rc"
      -DCMAKE_MT="$windows_mt"
      -DCMAKE_MSVC_RUNTIME_LIBRARY=MultiThreadedDLL
      -DCMAKE_C_FLAGS="$windows_c_flags"
      -DCMAKE_CXX_FLAGS="$windows_cxx_flags"
    )
  fi

  args+=("$@")
  "${args[@]}"
}

cmake_path_from_shell() {
  local path=$1
  if command -v cygpath >/dev/null 2>&1; then
    cygpath -m "$path"
  else
    printf '%s\n' "$path"
  fi
}

find_windows_exe() {
  local name=$1
  local label=$2
  local exe_name=$name
  case "$exe_name" in
    *.exe|*.EXE) ;;
    *) exe_name="$exe_name.exe" ;;
  esac

  if [[ "$exe_name" == *[\\/:]* ]]; then
    local candidate=$exe_name
    if command -v cygpath >/dev/null 2>&1; then
      candidate=$(cygpath -u "$exe_name" 2>/dev/null || printf '%s\n' "$exe_name")
    fi
    if [[ ! -x "$candidate" ]]; then
      echo "$label is not executable: $exe_name" >&2
      exit 2
    fi
    cmake_path_from_shell "$candidate"
    return
  fi

  local resolved
  resolved=$(command -v "$exe_name" 2>/dev/null || true)
  if [[ -z "$resolved" ]]; then
    echo "$label not found on PATH: $exe_name. Run from a Visual Studio Developer environment or import VsDevCmd before building Windows SDK artifacts." >&2
    exit 2
  fi
  cmake_path_from_shell "$resolved"
}

require_msvc_cl() {
  local compiler=$1
  local label=$2
  local base
  base=$(basename "$compiler" | tr '[:upper:]' '[:lower:]')
  if [[ "$base" != cl.exe && "$base" != cl ]]; then
    echo "$label must be MSVC cl.exe for Windows builds, got: $compiler" >&2
    exit 2
  fi

  local banner
  banner=$("$compiler" 2>&1 || true)
  if ! grep -qi 'Microsoft.*C/C++.*Compiler' <<< "$banner"; then
    echo "$label resolved to cl.exe but does not look like the Microsoft C/C++ compiler: $compiler" >&2
    exit 2
  fi

  case "$arch" in
    x86_64)
      if ! grep -qi 'for x64' <<< "$banner"; then
        echo "$label is MSVC cl.exe, but it does not appear to target x64 for windows-$arch: $compiler" >&2
        exit 2
      fi
      ;;
    aarch64)
      if ! grep -qi 'for ARM64' <<< "$banner"; then
        echo "$label is MSVC cl.exe, but it does not appear to target ARM64 for windows-$arch: $compiler" >&2
        exit 2
      fi
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
    case "${VSCMD_ARG_TGT_ARCH:-}" in
      "") ;;
      x64) [[ "$arch" == x86_64 ]] || { echo "MSVC environment targets x64, but requested windows-$arch." >&2; exit 2; } ;;
      arm64) [[ "$arch" == aarch64 ]] || { echo "MSVC environment targets arm64, but requested windows-$arch." >&2; exit 2; } ;;
      *) echo "Unsupported MSVC target architecture from VSCMD_ARG_TGT_ARCH=${VSCMD_ARG_TGT_ARCH:-}." >&2; exit 2 ;;
    esac

    windows_c_compiler=$(find_windows_exe "$windows_c_compiler" WINDOWS_CMAKE_C_COMPILER)
    windows_cxx_compiler=$(find_windows_exe "$windows_cxx_compiler" WINDOWS_CMAKE_CXX_COMPILER)
    windows_linker=$(find_windows_exe link WINDOWS_LINKER)
    windows_lib=$(find_windows_exe lib WINDOWS_LIB)
    windows_rc=$(find_windows_exe rc WINDOWS_RC)
    windows_mt=$(find_windows_exe mt WINDOWS_MT)
    windows_dumpbin=$(find_windows_exe dumpbin WINDOWS_DUMPBIN)

    require_msvc_cl "$windows_c_compiler" WINDOWS_CMAKE_C_COMPILER
    require_msvc_cl "$windows_cxx_compiler" WINDOWS_CMAKE_CXX_COMPILER
    echo "==> Native Windows build requested for $arch using MSVC: $windows_c_compiler"
    echo "==> Found MSVC linker/tools: $windows_linker; $windows_lib; $windows_rc; $windows_mt; $windows_dumpbin"
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

build_vulkan_tools() {
  cmake_install Vulkan-Tools "$src_dir/Vulkan-Tools" "$build_dir/vulkan-tools-$platform-$arch" \
    -DUPDATE_DEPS=ON \
    -DBUILD_TESTS=OFF \
    -DVULKAN_HEADERS_INSTALL_DIR="$common_prefix" \
    -DVULKAN_LOADER_INSTALL_DIR="$arch_prefix" \
    -DVULKAN_UTILITY_LIBRARIES_INSTALL_DIR="$arch_prefix"
}

build_validation_layers() {
  # This SDK build installs VVL's dependencies as first-class components above.
  # Keep VVL's update_deps.py disabled so Windows builds do not rebuild nested
  # SPIRV-Tools trees under the long checkout path, which can exceed MSVC's path
  # limits while compiling SPIRV-Tools-reduce sources.
  local extra=(
    -DUPDATE_DEPS=OFF
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
  cmake_install Vulkan-ExtensionLayer "$src_dir/Vulkan-ExtensionLayer" "$build_dir/extension-layer-$platform-$arch" \
    -DUPDATE_DEPS=ON \
    -DBUILD_TESTS=OFF \
    -DVULKAN_HEADERS_INSTALL_DIR="$common_prefix" \
    -DVULKAN_UTILITY_LIBRARIES_INSTALL_DIR="$arch_prefix"
}

build_vulkan_profiles() {
  cmake_install Vulkan-Profiles "$src_dir/Vulkan-Profiles" "$build_dir/profiles-$platform-$arch" \
    -DUPDATE_DEPS=ON \
    -DBUILD_TESTS=OFF \
    -DVULKAN_HEADERS_INSTALL_DIR="$common_prefix"
}

build_slang_component() {
  local slang_build="$build_dir/slang-$platform-$arch"
  local extra=(
    -DSLANG_USE_SYSTEM_VULKAN_HEADERS=OFF
    -DSLANG_USE_SYSTEM_GLSLANG=OFF
    -DSLANG_USE_SYSTEM_SPIRV_TOOLS=OFF
  )

  # Reuse Linux SPIR-V headers only. Reusing an installed SPIRV-Tools package
  # makes Slang's optional slang-glslang module emit bare -lSPIRV-Tools-* linker
  # flags on some runners, which can fail without matching -L search paths.
  # Slang's standalone glslang wrapper is disabled below; this SDK already ships
  # glslangValidator separately.
  if [[ "$platform" == linux ]]; then
    if has_component spirv-headers; then
      extra+=(-DSLANG_USE_SYSTEM_SPIRV_HEADERS=ON)
    else
      extra+=(-DSLANG_USE_SYSTEM_SPIRV_HEADERS=OFF)
    fi
  else
    extra+=(
      -DSLANG_USE_SYSTEM_SPIRV_HEADERS=OFF
    )
  fi

  if [[ -f "$slang_build/CMakeCache.txt" ]] && grep -Eq '^(SLANG_ENABLE_SLANG_GLSLANG|SLANG_USE_SYSTEM_SPIRV_TOOLS):[^=]*=ON' "$slang_build/CMakeCache.txt"; then
    echo "==> Removing stale Slang CMake build directory with incompatible dependency settings: $slang_build"
    rm -rf "$slang_build"
  fi

  cmake_install Slang "$src_dir/slang" "$slang_build" \
    -DSLANG_ENABLE_SLANGC=ON \
    -DSLANG_ENABLE_SLANGD=ON \
    -DSLANG_ENABLE_SLANGI=ON \
    -DSLANG_ENABLE_SLANGRT=ON \
    -DSLANG_ENABLE_SLANG_GLSLANG=OFF \
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
