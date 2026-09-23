#!/usr/bin/env python3
"""Apply the AlphaFold3-on-AMD source patches described in the README.
See https://github.com/amd/HPCTrainingDock/tree/main/extras/scripts/alphafold3

This automates the four manual edits from the "Before we run, we have to apply
several patches" section of the AlphaFold3 README, so they can be applied (and
re-applied) reliably. The patches are needed because `tokamax` gates its Triton
kernels on an NVIDIA-style numeric `compute_capability`, which is a *string*
(e.g. ``gfx90a``) on AMD/ROCm devices and therefore crashes ``float(...)``.

The four patches:
  1. ``<af3-repo>/run_alphafold.py``               -- force compute_capability = 642
  2. ``tokamax/_src/triton.py``                    -- handle string compute_capability
  3. ``tokamax/_src/precision.py``                 -- don't crash on string cc
  4. ``tokamax/_src/ops/attention/pallas_triton_flash_attention.py``
                                                   -- drop the "Triton not supported" guard

Every patch is *idempotent* (re-running is a no-op) and *content-anchored*
(it matches on the original code text, not line numbers, which drift between
versions). If an expected block is missing AND the patch is not already
applied, a WARNING is printed and the tool moves on -- it never leaves a file
half-edited. A ``.af3-orig`` backup is written the first time a file is changed.

Usage:
    python3 apply_af3_patches.py --af3-repo /path/to/alphafold3

`tokamax` is located automatically inside the active Python environment. Verified
against tokamax==0.0.4 and AlphaFold3 commit 3a09f04.
"""

import argparse
import importlib.util
import re
import sys
from pathlib import Path

# A large fake compute capability (>= 8.0) so tokamax's "Ampere or newer"
# Triton checks pass on AMD GPUs. Matches the README's value.
FAKE_COMPUTE_CAPABILITY = 642

GREEN, YELLOW, RED, RESET = "\033[32m", "\033[33m", "\033[31m", "\033[0m"


def _ok(msg):
    print(f"{GREEN}[ok]{RESET} {msg}")


def _warn(msg):
    print(f"{YELLOW}[warn]{RESET} {msg}")


def _skip(msg):
    print(f"{GREEN}[skip]{RESET} {msg} (already patched)")


class PatchError(RuntimeError):
    pass


def apply_patch(path: Path, already_marker: str, pattern: str, replacement: str,
                *, flags=0, label: str) -> bool:
    """Apply one content-anchored patch to `path`.

    Returns True if the file was modified, False if it was already patched.
    Raises PatchError if neither the marker nor the pattern is found (so the
    caller can downgrade it to a warning rather than aborting the whole run).
    """
    if not path.is_file():
        raise PatchError(f"{label}: file not found: {path}")

    text = path.read_text()

    if already_marker in text:
        _skip(f"{label}: {path}")
        return False

    new_text, n = re.subn(pattern, replacement, text, flags=flags)
    if n == 0:
        raise PatchError(
            f"{label}: could not find the expected code in {path}. "
            f"The file layout may have changed for this version -- apply the "
            f"patch by hand per the README."
        )

    # Back up the pristine file exactly once, then write the patched version.
    backup = path.with_suffix(path.suffix + ".af3-orig")
    if not backup.exists():
        backup.write_text(text)
    path.write_text(new_text)
    _ok(f"{label}: patched {path} ({n} site{'s' if n != 1 else ''})")
    return True


def find_tokamax() -> Path:
    """Locate the installed tokamax package without importing jax."""
    spec = importlib.util.find_spec("tokamax")
    if spec is None or not spec.submodule_search_locations:
        raise PatchError(
            "tokamax is not installed in the active environment. Install "
            "AlphaFold3 first, then re-run this script."
        )
    return Path(list(spec.submodule_search_locations)[0])


def patch_run_alphafold(af3_repo: Path) -> None:
    """Patch 1: force a numeric compute_capability in run_alphafold.py."""
    path = af3_repo / "run_alphafold.py"
    # Original (multi-line):
    #       compute_capability = float(
    #           gpu_devices[_GPU_DEVICE.value].compute_capability
    #       )
    pattern = (
        r"compute_capability\s*=\s*float\(\s*"
        r"gpu_devices\[_GPU_DEVICE\.value\]\.compute_capability\s*\)"
    )
    replacement = f"compute_capability = {FAKE_COMPUTE_CAPABILITY}"
    apply_patch(
        path,
        already_marker=f"compute_capability = {FAKE_COMPUTE_CAPABILITY}",
        pattern=pattern,
        replacement=replacement,
        flags=re.DOTALL,
        label="run_alphafold.py",
    )


def patch_triton(tokamax: Path) -> None:
    """Patch 2: make has_triton_support tolerate a string compute_capability."""
    path = tokamax / "_src" / "triton.py"
    # Original last line of has_triton_support():
    #   return float(device.compute_capability) >= 8.0
    pattern = r"return float\(device\.compute_capability\) >= 8\.0"
    replacement = (
        "cc = device.compute_capability\n"
        "  if isinstance(cc, str):\n"
        "    return False\n"
        "  return float(cc) >= 8.0"
    )
    apply_patch(
        path,
        already_marker="cc = device.compute_capability",
        pattern=pattern,
        replacement=replacement,
        label="tokamax/_src/triton.py",
    )


def patch_precision(tokamax: Path) -> None:
    """Patch 3: don't crash in precision.py when cc is a (string) AMD arch."""
    path = tokamax / "_src" / "precision.py"
    # Original:
    #     elif float(compute_capability) < 8.0:
    #       backend = "gpu_old"
    pattern = (
        r' {4}elif float\(compute_capability\) < 8\.0:\n'
        r' {6}backend = "gpu_old"'
    )
    replacement = (
        '    elif compute_capability is not None:\n'
        '      try:\n'
        '        if float(compute_capability) < 8.0:\n'
        '          backend = "gpu_old"\n'
        '      except (TypeError, ValueError):\n'
        '        pass'
    )
    apply_patch(
        path,
        already_marker="except (TypeError, ValueError):",
        pattern=pattern,
        replacement=replacement,
        label="tokamax/_src/precision.py",
    )


def patch_flash_attention(tokamax: Path) -> None:
    """Patch 4: drop the hard 'Triton not supported' guard on AMD."""
    path = tokamax / "_src" / "ops" / "attention" / "pallas_triton_flash_attention.py"
    # Original:
    #     if not triton_lib.has_triton_support():
    #       raise NotImplementedError("Triton not supported on this platform.")
    pattern = (
        r' {4}if not triton_lib\.has_triton_support\(\):\n'
        r' {6}raise NotImplementedError\("Triton not supported on this platform\."\)'
    )
    replacement = (
        '    if not triton_lib.has_triton_support():\n'
        '      pass  # AF3-on-AMD: Triton support is forced on for ROCm'
    )
    apply_patch(
        path,
        already_marker="# AF3-on-AMD: Triton support is forced on",
        pattern=pattern,
        replacement=replacement,
        label="tokamax/.../pallas_triton_flash_attention.py",
    )


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument(
        "--af3-repo", type=Path, required=True,
        help="Path to the cloned alphafold3 repository (contains run_alphafold.py).",
    )
    args = parser.parse_args()

    failures = 0
    try:
        tokamax = find_tokamax()
        print(f"Found tokamax at: {tokamax}\n")
    except PatchError as e:
        _warn(str(e))
        return 1

    patches = [
        ("run_alphafold.py", lambda: patch_run_alphafold(args.af3_repo)),
        ("triton.py", lambda: patch_triton(tokamax)),
        ("precision.py", lambda: patch_precision(tokamax)),
        ("pallas_triton_flash_attention.py", lambda: patch_flash_attention(tokamax)),
    ]
    for name, fn in patches:
        try:
            fn()
        except PatchError as e:
            _warn(str(e))
            failures += 1

    print()
    if failures:
        _warn(f"{failures} patch(es) could not be applied automatically -- "
              f"see the README's patch section and apply them by hand.")
        return 1
    _ok("All AlphaFold3-on-AMD patches are in place.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
