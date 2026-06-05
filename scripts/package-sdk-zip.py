#!/usr/bin/env python3
import argparse
import os
import zipfile
from pathlib import Path, PurePosixPath


def add_file(archive, source, archive_name):
    info = zipfile.ZipInfo(str(archive_name))
    info.create_system = 3
    info.compress_type = zipfile.ZIP_DEFLATED

    if source.name.endswith(".sh") or source.suffix.lower() == ".exe":
        mode = 0o755
    else:
        mode = 0o644
    info.external_attr = mode << 16

    with source.open("rb") as file:
        archive.writestr(info, file.read())


def add_tree(archive, source_dir, archive_dir):
    for source in sorted(source_dir.rglob("*")):
        if not source.is_file():
            continue
        relative = PurePosixPath(source.relative_to(source_dir).as_posix())
        add_file(archive, source, PurePosixPath(archive_dir) / relative)


def main():
    parser = argparse.ArgumentParser(description="Package a Vulkan SDK Windows ZIP with portable member paths.")
    parser.add_argument("sdk_root", type=Path, help="Path to dist/vulkan-sdk-<version>")
    parser.add_argument("platform", choices=("windows",), help="Platform name")
    parser.add_argument("arch", choices=("x86_64", "aarch64"), help="Architecture name")
    parser.add_argument("output", nargs="?", type=Path, help="Output .zip path")
    args = parser.parse_args()

    prefix = args.sdk_root / f"{args.platform}-{args.arch}"
    sdk_root_name = PurePosixPath(args.sdk_root.name)
    setup_env_sh = args.sdk_root / "setup-env.sh"
    setup_env_ps1 = args.sdk_root / "setup-env.ps1"
    for path in (prefix, setup_env_sh, setup_env_ps1):
        if not path.exists():
            raise SystemExit(f"Missing package input: {path}")

    if args.output is None:
        args.output = args.sdk_root.parent / f"{args.sdk_root.name}-{args.platform}-{args.arch}.zip"

    args.output.parent.mkdir(parents=True, exist_ok=True)
    temporary_output = args.output.with_suffix(args.output.suffix + ".tmp")
    if temporary_output.exists():
        temporary_output.unlink()

    try:
        with zipfile.ZipFile(temporary_output, "w") as archive:
            add_tree(archive, prefix, sdk_root_name / prefix.name)
            add_file(archive, setup_env_sh, sdk_root_name / setup_env_sh.name)
            add_file(archive, setup_env_ps1, sdk_root_name / setup_env_ps1.name)
        os.replace(temporary_output, args.output)
    finally:
        if temporary_output.exists():
            temporary_output.unlink()


if __name__ == "__main__":
    main()
