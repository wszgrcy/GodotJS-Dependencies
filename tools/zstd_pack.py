#!/usr/bin/env python3
"""Write and read the .tar.zst release asset for one platform's bundle.

zstd is used instead of zip because these bundles are dominated by static
archives that shrink far better under a strong zstd setting than under deflate.
python is used instead of a `zstd` command line because the Windows runners have
no zstd on PATH; `pip install zstandard` is the one dependency, and the wheels
cover every platform in the build matrix.

The archive layout is `node/include/...` plus `node/<platform>.<arch>.release/...`
under the top level, the same shape the release carried when it was a zip.
"""

import argparse
import os
import sys
import tarfile

try:
    import zstandard
except ImportError:
    sys.exit("the zstandard module is missing; install it with: python3 -m pip install zstandard")

# 15 is well past the point of diminishing returns for these files, and stays
# fast enough to not dominate a build job. The maximum is 22.
DEFAULT_LEVEL = 15


def _reproducible(info):
    """Drop owner and timestamp noise so the same bundle packs to the same bytes."""
    info.uid = 0
    info.gid = 0
    info.uname = ""
    info.gname = ""
    info.mtime = 0
    return info


def pack(directory, name, out_path, level, threads):
    source = os.path.join(directory, name)
    if not os.path.isdir(source):
        raise SystemExit(f"{source} is not a directory; nothing to pack")
    compressor = zstandard.ZstdCompressor(level=level, threads=threads)
    with open(out_path, "wb") as raw:
        with compressor.stream_writer(raw, closefd=False) as compressed:
            with tarfile.open(fileobj=compressed, mode="w|") as tar:
                tar.add(source, arcname=name, filter=_reproducible)
    if os.path.getsize(out_path) == 0:
        raise SystemExit(f"{out_path} was written empty")
    return os.path.getsize(out_path)


def unpack(archive, into):
    decompressor = zstandard.ZstdDecompressor()
    with open(archive, "rb") as raw:
        with decompressor.stream_reader(raw) as stream:
            with tarfile.open(fileobj=stream, mode="r|") as tar:
                tar.extractall(into, filter="data")
    return len(
        [os.path.join(dirpath, f) for dirpath, _, files in os.walk(into) for f in files]
    )


def main():
    parser = argparse.ArgumentParser()
    sub = parser.add_subparsers(dest="command", required=True)

    pack_cmd = sub.add_parser("pack", help="write <name>/ from <directory> into one .tar.zst")
    pack_cmd.add_argument("--directory", required=True, help="directory that contains the bundle")
    pack_cmd.add_argument("--name", required=True, help="top-level entry, usually node")
    pack_cmd.add_argument("--out", required=True, help="path of the .tar.zst to write")
    pack_cmd.add_argument("--level", type=int, default=DEFAULT_LEVEL)
    pack_cmd.add_argument(
        "--threads",
        type=int,
        default=0,
        help="compression threads; 0 means one per core (default), -1 means single threaded",
    )

    unpack_cmd = sub.add_parser("unpack", help="read a .tar.zst back out; used by the pre-flight check")
    unpack_cmd.add_argument("--archive", required=True)
    unpack_cmd.add_argument("--into", required=True)

    args = parser.parse_args()
    if args.command == "pack":
        # zstandard takes 0 as "all cores" already, but -1 reads better in a log.
        threads = os.cpu_count() if args.threads == 0 else args.threads
        size = pack(args.directory, args.name, args.out, args.level, threads)
        source = sum(
            os.path.getsize(os.path.join(dirpath, f))
            for dirpath, _, files in os.walk(os.path.join(args.directory, args.name))
            for f in files
        )
        print(
            f"zstd_pack: level {args.level} threads {threads}: "
            f"{source / 1e6:.1f} MB -> {size / 1e6:.2f} MB "
            f"({source / size:.1f}x) -> {args.out}"
        )
    else:
        os.makedirs(args.into, exist_ok=True)
        files = unpack(args.archive, args.into)
        print(f"zstd_pack: {args.archive} unpacked {files} files into {args.into}")


if __name__ == "__main__":
    main()
