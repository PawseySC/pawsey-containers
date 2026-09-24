# FreeBindCraft v1.0.5 (ROCm 7.0.2, no PyRosetta): container tests

## 1. Build (podman build node)

```bash
./build.sh
```

This builds `../Dockerfile` with podman, converts the image to `$MYSCRATCH/gpu_biology_builds/freebindcraft_v1.0.5-rocm7.0.2.sif`, and runs quick checks inside it (imports, `bindcraft.py --help`, bundled `dssp`/`DAlphaBall.gcc` executable, image title label). It ends with `OVERALL: PASS` or `OVERALL: FAIL`.

## 2. Test on the GPU partition (Setonix)

```bash
sbatch --account=<project>-gpu freebindcraft_tests.sh /path/to/freebindcraft_v1.0.5-rocm7.0.2.sif
```

Each test runs as one array task on one GCD. When they have all finished, a summary job writes `freebindcraft-tests_<jobid>_summary.out` in the directory you submitted from, with one PASS/FAIL/SKIP line per test. Each test's full log is in `freebindcraft-tests_<jobid>_<test#>.out`, and its outputs are in `$MYSCRATCH/gpu_biology_tests/freebindcraft/<jobid>/`.

## What is tested

The design tests use FreeBindCraft's own PD-L1 example (`/app/FreeBindCraft/example/PDL1.pdb`, hotspot residue 56) with `--no-pyrosetta --no-plots --no-animations`. `inputs/make_settings.py` starts from the image's settings preset and shortens it: 20/10/2/3 soft/temporary/hard/greedy iterations, 1 trajectory, 4 MPNN sequences.

FreeBindCraft keeps designing until one trajectory is good enough to relax, which can take a while with shortened settings. The design tests therefore stop after `DESIGN_TIME_LIMIT` and pass as long as at least one trajectory was written without an error.

| # | Test | What runs | Passes when |
|---|------|-----------|-------------|
| 0 | `gpu_check` | JAX matrix multiply on the GPU; `import colabdesign` | JAX reports a GPU device and the result is correct |
| 1 | `binder_design` | `bindcraft.py`, `default_4stage_multimer` preset + `default_filters`, 50-60 residue binder | a trajectory PDB is written; the run finishes or reaches the time limit |
| 2 | `peptide_design` | `bindcraft.py`, `peptide_3stage_multimer` preset + `peptide_filters`, 10-15 residue peptide | as 1 |
| 3 | `openmm_relax` | FreeBindCraft's OpenMM relax (its PyRosetta replacement) on `PDL1.pdb` | structure changed, and relax ran on a GPU platform (HIP or OpenCL) |

## Settings

Set these in the environment when you submit, e.g. `DESIGN_TIME_LIMIT=40m sbatch ...`.

| Variable | Default | Meaning |
|----------|---------|---------|
| `FBC_PARAMS_DIR` | `/scratch/references/alphafold_feb2024/databases` | FreeBindCraft `af_params_dir`; must contain `params/` with the AlphaFold2 multimer v3 weights |
| `DESIGN_TIME_LIMIT` | `25m` | Maximum run time of `bindcraft.py` in tests 1-2 (`timeout` syntax); keep it below the job `--time` |
| `SINGULARITY_MODULE` | `singularity/3.11.4-nompi` | Module that provides `singularity` |
| `SINGULARITY_ARGS` | *(empty)* | Extra `singularity exec` options, e.g. `--bind /software` |
| `OUTPUT_ROOT` | `$MYSCRATCH/gpu_biology_tests` | Where test outputs go |
| `SUMMARY_SBATCH_ARGS` | `--nodes=1 --gres=gpu:1 --time=00:05:00` | Resources for the summary job |

`build.sh` settings: `BUILD_DIR` (default `$MYSCRATCH/gpu_biology_builds`), `PODMAN_JOBS` (default `4`), `KEEP_OCI_ARCHIVE=1` to keep the intermediate `.tar`.

## Inputs

- `make_settings.py`: writes `target.json` and `advanced.json` for a short run. Edit it to change the target, binder lengths or iteration counts.
