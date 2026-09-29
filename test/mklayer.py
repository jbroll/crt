#!/usr/bin/env python3
"""Write a gzipped tar layer with exactly the members given, for OCI tests.

usage: mklayer.py [--pax] OUT.tgz SPEC...
  f:NAME          regular file (content "x")
  d:NAME          directory
  l:NAME:TARGET   symlink NAME -> TARGET
  h:NAME:TARGET   hardlink NAME -> TARGET
Names are written verbatim, so '..', absolute names and names containing
" -> " or " link to " can be crafted. --pax writes a PAX archive with
sub-second mtimes.
"""
import io
import sys
import tarfile


def main(out, specs, pax=False):
    fmt = tarfile.PAX_FORMAT if pax else tarfile.GNU_FORMAT
    with tarfile.open(out, "w:gz", format=fmt) as tar:
        for spec in specs:
            kind, _, rest = spec.partition(":")
            name, _, target = rest.partition(":")
            info = tarfile.TarInfo(name)
            info.mtime = 1600000000.123456 if pax else 0
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
    args = sys.argv[1:]
    pax = bool(args) and args[0] == "--pax"
    if pax:
        args = args[1:]
    if len(args) < 2:
        sys.exit(__doc__)
    main(args[0], args[1:], pax)
