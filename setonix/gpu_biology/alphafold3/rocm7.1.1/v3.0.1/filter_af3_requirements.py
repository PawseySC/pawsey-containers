#!/usr/bin/env python3
"""Rewrite AlphaFold3's requirements.txt for a ROCm/JAX-from-pip install.

AlphaFold3's pip-compiled requirements.txt pins the CUDA JAX stack (jax[cuda12],
jax-cuda12-*, jaxlib) and the NVIDIA CUDA wheels, all with hashes. On AMD/ROCm we
install JAX from ROCm wheels separately, so those pins must go. Following the
README, this drops every ``jax*`` and ``nvidia-*`` requirement EXCEPT
``jax-triton`` and ``jaxtyping``, strips the hashes and any ``[extras]``, and
writes a plain ``name==version`` list suitable for::

    pip install --no-build-isolation --no-deps -r <output>

Usage:
    python3 filter_af3_requirements.py requirements.txt requirements.rocm.txt

Verified against AlphaFold3 commit 3a09f04 (drops 4 jax + 12 nvidia pins,
keeps jax-triton / jaxtyping / triton).
"""

import re
import sys


def filter_requirements(src_text: str) -> list[str]:
    # Match top-level package declarations: "name[extras]==version" at column 0.
    decl = re.compile(r'^([A-Za-z0-9][A-Za-z0-9._-]*)(\[[^\]]*\])?==([^\s\\]+)', re.M)
    kept = []
    for m in decl.finditer(src_text):
        base = m.group(1).lower()
        if base in ("jax", "jaxlib") or base.startswith("jax-cuda") or base.startswith("nvidia-"):
            continue  # drop the CUDA JAX stack + NVIDIA wheels
        kept.append(f"{m.group(1)}=={m.group(3)}")  # drop [extras] and hashes
    return kept


def main(argv: list[str]) -> int:
    if len(argv) != 3:
        print(__doc__)
        return 2
    src_path, out_path = argv[1], argv[2]
    with open(src_path) as f:
        kept = filter_requirements(f.read())
    with open(out_path, "w") as f:
        f.write("\n".join(kept) + "\n")
    print(f"wrote {len(kept)} requirements -> {out_path}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
