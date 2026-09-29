#!/usr/bin/env python3
"""Write a gzipped tar layer with exactly the members given, for OCI tests.

usage: mklayer.py OUT.tgz SPEC...
  f:NAME          regular file (content "x")
  d:NAME          directory
  l:NAME:TARGET   symlink NAME -> TARGET
  h:NAME:TARGET   hardlink NAME -> TARGET
Names are written verbatim, so '..' and absolute names can be crafted.
"""
import io
import sys
import tarfile


def main(out, specs):
    with tarfile.open(out, "w:gz") as tar:
        for spec in specs:
            kind, _, rest = spec.partition(":")
            name, _, target = rest.partition(":")
            info = tarfile.TarInfo(name)
            info.mtime = 0
            data = None
            if kind == "f":
                payload = b"x\n"
                info.size = len(payload)
                data = io.BytesIO(payload)
            elif kind == "d":
                info.type = tarfile.DIRTYPE
                info.mode = 0o755
            elif kind == "l":
                info.type = tarfile.SYMTYPE
                info.linkname = target
            elif kind == "h":
                info.type = tarfile.LNKTYPE
                info.linkname = target
            else:
                sys.exit(f"bad spec: {spec}")
            tar.addfile(info, data)


if __name__ == "__main__":
    if len(sys.argv) < 3:
        sys.exit(__doc__)
    main(sys.argv[1], sys.argv[2:])
