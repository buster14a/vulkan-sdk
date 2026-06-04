#!/usr/bin/env bash
set -euo pipefail

sdk_dir=${1:-dist/custom-vulkan-sdk}
max_glibc=${MAX_GLIBC_VERSION:-}

if [[ ! -d "$sdk_dir" ]]; then
  echo "SDK directory does not exist: $sdk_dir" >&2
  exit 2
fi

if ! command -v readelf >/dev/null 2>&1; then
  echo "readelf is required; install binutils." >&2
  exit 2
fi

version_gt() {
  local a=$1
  local b=$2
  [[ "$(printf '%s\n%s\n' "$a" "$b" | sort -V | tail -n1)" == "$a" && "$a" != "$b" ]]
}

check_arch() {
  local path=$1
  local expected=$2

  if [[ ! -e "$path" ]]; then
    echo "Missing expected file: $path" >&2
    return 1
  fi

  echo "==> $path"
  file -L "$path"
  file -L "$path" | grep -Eq "$expected"
}

check_glibc_floor() {
  local file=$1
  [[ -n "$max_glibc" ]] || return 0

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

check_arch "$sdk_dir/linux-x86_64/lib/libvulkan.so" 'x86-64'
check_arch "$sdk_dir/linux-aarch64/lib/libvulkan.so" 'ARM aarch64'

status=0
while IFS= read -r -d '' elf; do
  echo "==> Dynamic dependencies for $elf"
  readelf -d "$elf" | grep '(NEEDED)' || true
  check_glibc_floor "$elf" || status=1
done < <(find "$sdk_dir" -type f \( -name '*.so' -o -name '*.so.*' \) -print0)

if [[ "$status" -ne 0 ]]; then
  exit "$status"
fi

if [[ -n "$max_glibc" ]]; then
  echo "Compatibility check passed: no checked ELF requires newer than GLIBC_$max_glibc."
else
  echo "Compatibility check passed: GLIBC floor not enforced."
fi
