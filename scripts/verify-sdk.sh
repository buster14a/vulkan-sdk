#!/usr/bin/env bash
set -euo pipefail

sdk_dir=${1:-dist/vulkan-sdk-1.4.350.0}
platform=${2:-}
arch=${3:-}
max_glibc=${MAX_GLIBC_VERSION:-}
build_slang=${BUILD_SLANG:-ON}

usage() {
  echo "Usage: scripts/verify-sdk.sh [sdk-dir] <linux|windows|macos> <x86_64|aarch64>" >&2
}

if [[ -z "$platform" || -z "$arch" ]]; then
  usage
  exit 2
fi

case "$platform" in
  linux|windows|macos) ;;
  *) usage; exit 2 ;;
esac
case "$arch" in
  x86_64|aarch64) ;;
  *) usage; exit 2 ;;
esac

normalize_bool() {
  local name=$1
  local value=$2
  case "$value" in
    ON|On|on|TRUE|True|true|1|YES|Yes|yes) echo ON ;;
    OFF|Off|off|FALSE|False|false|0|NO|No|no) echo OFF ;;
    *) echo "$name must be ON or OFF, got: $value" >&2; return 2 ;;
  esac
}
build_slang=$(normalize_bool BUILD_SLANG "$build_slang")

unix_find() {
  local candidate
  for candidate in /usr/bin/find /bin/find; do
    if [[ -x "$candidate" ]]; then
      "$candidate" "$@"
      return
    fi
  done

  command find "$@"
}

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

prefix="$sdk_dir/$platform-$arch"
if [[ ! -d "$prefix" ]]; then
  echo "SDK prefix does not exist: $prefix" >&2
  exit 1
fi

require_file() {
  local path=$1
  if [[ ! -e "$path" ]]; then
    echo "Missing expected file: $path" >&2
    exit 1
  fi
}

require_any_file() {
  local path
  for path in "$@"; do
    if [[ -e "$path" ]]; then
      return 0
    fi
  done
  echo "Missing expected file; tried: $*" >&2
  exit 1
}

require_exe() {
  local name=$1
  if [[ "$platform" == windows ]]; then
    require_file "$prefix/bin/$name.exe"
  else
    require_file "$prefix/bin/$name"
  fi
}

require_match() {
  local description=$1
  shift
  if ! unix_find "$prefix" "$@" | grep -q .; then
    echo "Missing expected $description" >&2
    exit 1
  fi
}

verify_slang_spirv_compile() {
  local slangc="$prefix/bin/slangc"
  if [[ "$platform" == windows ]]; then
    slangc="$prefix/bin/slangc.exe"
  fi

  local tmp_dir
  tmp_dir=$(mktemp -d "${TMPDIR:-/tmp}/vulkan-sdk-slang.XXXXXX")
  cat > "$tmp_dir/smoke.slang" <<'SLANG'
[shader("compute")]
[numthreads(1, 1, 1)]
void main() {}
SLANG

  local status=0
  "$slangc" "$tmp_dir/smoke.slang" \
    -entry main \
    -stage compute \
    -target spirv \
    -emit-spirv-directly \
    -o "$tmp_dir/smoke.spv" || status=$?
  if [[ "$status" -ne 0 ]]; then
    rm -rf "$tmp_dir"
    exit "$status"
  fi
  if [[ ! -s "$tmp_dir/smoke.spv" ]]; then
    echo "Slang SPIR-V smoke compile did not produce output: $tmp_dir/smoke.spv" >&2
    rm -rf "$tmp_dir"
    exit 1
  fi
  rm -rf "$tmp_dir"
}

version_gt() {
  local a=$1
  local b=$2
  [[ "$(printf '%s\n%s\n' "$a" "$b" | sort -V | tail -n1)" == "$a" && "$a" != "$b" ]]
}

check_glibc_floor() {
  local file=$1
  [[ -n "$max_glibc" ]] || return 0
  command -v readelf >/dev/null 2>&1 || return 0

  local status=0
  local versions
  versions=$(readelf --version-info "$file" 2>/dev/null | grep -oE 'GLIBC_[0-9]+(\.[0-9]+)+' | sed 's/^GLIBC_//' | sort -Vu || true)
  while IFS= read -r version; do
    [[ -z "$version" ]] && continue
    if version_gt "$version" "$max_glibc"; then
      echo "ERROR: $file requires GLIBC_$version, newer than baseline GLIBC_$max_glibc" >&2
      status=1
    fi
  done <<< "$versions"
  return "$status"
}

check_file_type() {
  local path=$1
  local expected=$2
  command -v file >/dev/null 2>&1 || return 0
  echo "==> $path"
  file -L "$path"
  file -L "$path" | grep -Eq "$expected"
}

if has_component vulkan-loader; then
  case "$platform" in
    linux)
      require_file "$prefix/lib/libvulkan.so"
      case "$arch" in
        x86_64) check_file_type "$prefix/lib/libvulkan.so" 'x86-64' ;;
        aarch64) check_file_type "$prefix/lib/libvulkan.so" 'ARM aarch64' ;;
      esac
      while IFS= read -r -d '' elf; do
        check_glibc_floor "$elf"
      done < <(unix_find "$prefix" -type f \( -name '*.so' -o -name '*.so.*' \) -print0)
      ;;
    macos)
      require_file "$prefix/lib/libvulkan.dylib"
      case "$arch" in
        x86_64) check_file_type "$prefix/lib/libvulkan.dylib" 'x86_64' ;;
        aarch64) check_file_type "$prefix/lib/libvulkan.dylib" 'arm64|aarch64' ;;
      esac
      ;;
    windows)
      require_any_file \
        "$prefix/lib/vulkan-1.lib" \
        "$prefix/lib/libvulkan-1.dll.a" \
        "$prefix/lib/libvulkan.dll.a"
      require_file "$prefix/bin/vulkan-1.dll"
      ;;
  esac
fi

has_component vulkan-headers && require_file "$prefix/include/vulkan/vulkan.h"
has_component spirv-tools && require_exe spirv-val
has_component spirv-tools && require_exe spirv-opt
has_component glslang && require_exe glslangValidator
has_component spirv-cross && require_exe spirv-cross
has_component shaderc && require_exe glslc
has_component vulkan-tools && require_exe vulkaninfo
has_component vulkan-validationlayers && require_match "Vulkan validation layer" -iname '*khronos_validation*'
has_component vulkan-extensionlayer && require_match "Vulkan extension layer artifact" -iname '*VkLayer*'
has_component vulkan-profiles && require_match "Vulkan profiles artifact" -iname '*profile*'
has_component slang && require_exe slangc

if has_component slang; then
  case "$platform" in
    linux) require_match "Slang glslang runtime module" -name 'libslang-glslang-*.so' ;;
    macos) require_match "Slang glslang runtime module" -name 'libslang-glslang-*.dylib' ;;
    windows) require_match "Slang glslang runtime module" -iname 'slang-glslang*.dll' ;;
  esac
  verify_slang_spirv_compile
fi

echo "SDK verification passed for $platform-$arch with components: $components"
