# OpenFOAM host-library link diagnostics

[openfoamLinkDiagnostics.slurm.sh](./openfoamLinkDiagnostics.slurm.sh) is a
separate diagnostic job for the OpenFOAM 10 `icoFoam` development workflow.
It leaves the normal compile-tool test and module definitions unchanged.

From the OpenFOAM directory, submit:

```bash
sbatch tests/setonix/openfoamLinkDiagnostics.slurm.sh \
  --image openfoam-org/10/artifacts/singularity/latest/openfoam-org--10-gcc13DPInt32Opt-mpich4.2.2-ubuntu24.04.sif \
  --output-dir openfoam-org/10/artifacts/tests/link-diagnostics \
  --singularity-module singularity/4.3.5-mpi
```

The job uses one node in `work` for up to 15 minutes. Override Slurm settings
before the script argument if necessary. Run from a shell without additional
`SINGULARITY_BIND`, `APPTAINER_BIND`, or `APPTAINER_BINDPATH` settings.
The selected module must use selective binds, not the broad host-directory bind.

All four cases use the same module, image, preload settings, and JSON-C binds:

| Case | Change relative to the module's selective binds |
|---|---|
| A-selective | None |
| B-host-libnl | Also bind host `libnl-3.so.200` into `/host_lib64` |
| C-host-libnl-pair | Also bind host `libnl-3.so.200` and `libnl-genl-3.so.200` into `/host_lib64` |
| D-host-directory | Replace the Lustre-only `/host_lib64` mapping with `/usr/lib64:/host_lib64` |

Each case copies and renames `icoFoam` in its own new directory, compiles with
`wmake`, and checks the resulting executable's help output if compilation
succeeds. The only added link flags are `--trace` and `--verbose`, for diagnostics.
No existing build directories are deleted or reused.

The output directory contains a unique run directory with:

- `results.tsv`: per-case compile/diagnostic and help exit statuses.
- `module.txt`, `image.sha256`, and `host-libraries.txt`: baseline identity and ELF data.
- Per-case host and container environment records and container library ELF data.
- Per-case `compile.log`: compiler commands, linker search trace, and errors.
- Per-case build products, `binary-ldd.txt`, and `help.log` when available.
- `job.log` and `job.exit-status.txt`: overall execution evidence.

Look in the linker trace for `libnl-3.so.200`, especially lines reporting
`needed by`, `trying file`, or `found`. Compare A with B before attributing the
result to search priority. A bind makes a file visible; it does not itself give
that file priority. Preloading libraries into the linker process is distinct
from resolving dependencies of the executable being linked.

The job continues through expected case failures, then exits nonzero if any
case failed. A Slurm `FAILED` state can therefore be the expected outcome of
this experiment; consult `results.tsv`. Missing rows or a missing final status
can indicate setup failure, cancellation, or timeout.

## Verified result on 2026-10-26

Slurm job `397947`, using `singularity/4.3.5-mpi` and the OpenFOAM 10 image
above, produced:

| Case | Compilation | Executable help |
|---|---|---|
| A-selective | Failed with unresolved `@libnl_3` symbols | Not run |
| B-host-libnl | Passed | Passed |
| C-host-libnl-pair | Passed | Passed |
| D-host-directory | Passed | Passed |

The baseline linker trace first tried `/host_lib64/libnl-3.so.200`, where
no file was present, then selected `/lib/x86_64-linux-gnu/libnl-3.so.200`.
Case B instead selected `/host_lib64/libnl-3.so.200`. Host CXI requires
`libnl_3`-versioned symbols; the host libnl exports them, while the image's
libnl exports the corresponding symbols without that version label.

For this compile/help test, adding the following entry to the selective
`SINGULARITY_BINDPATH` was sufficient, without changing preloads or JSON-C:

```text
/usr/lib64/libnl-3.so.200:/host_lib64/libnl-3.so.200
```

This does not establish that every other host MPI application or dependency
is covered. Validate the normal compile test and MPI tutorial workflow after
any module change.
