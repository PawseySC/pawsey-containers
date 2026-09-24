# ColabFold v1.6.1 (ROCm 7.0.2): container tests

## 1. Build (podman build node)

```bash
./build.sh
```

This builds `../Dockerfile` with podman, converts the image to `$MYSCRATCH/gpu_biology_builds/colabfold_v1.6.1-rocm7.0.2.sif`, and runs quick checks inside it (imports, `colabfold_batch`/`colabfold_search --help`, the CUDA→HIP relax patch, MSA tools on `PATH`, image title label). It ends with `OVERALL: PASS` or `OVERALL: FAIL`.

## 2. Test on the GPU partition (Setonix)

```bash
sbatch --account=<project>-gpu colabfold_tests.sh /path/to/colabfold_v1.6.1-rocm7.0.2.sif
```

Each test runs as one array task on one GCD. When they have all finished, a summary job writes `colabfold-tests_<jobid>_summary.out` in the directory you submitted from, with one PASS/FAIL/SKIP line per test. Each test's full log is in `colabfold-tests_<jobid>_<test#>.out`, and its outputs are in `$MYSCRATCH/gpu_biology_tests/colabfold/<jobid>/`.

Test 5 searches the local databases (slow) and test 6 needs internet access from the compute node, so they only run if you ask for them:

```bash
sbatch --account=<project>-gpu --array=0-6 --time=03:00:00 colabfold_tests.sh IMAGE
```

## What is tested

All `colabfold_batch` runs use 1 model, 3 recycles and seed 0. The protein is 112 residues (chain A), with a 116-residue partner (chain B) in the dimer test.

| # | Test | What runs | Passes when |
|---|------|-----------|-------------|
| 0 | `gpu_check` | JAX matrix multiply on the GPU | JAX reports a GPU device and the result is correct |
| 1 | `monomer` | `colabfold_batch chainA.a3m`, `alphafold2_ptm` | rank-1 model and scores written, mean pLDDT ≥ `MIN_PLDDT` |
| 2 | `monomer_amber_gpu` | as 1, plus `--amber --use-gpu-relax` (OpenMM HIP) | as 1, plus a relaxed model |
| 3 | `heterodimer` | `colabfold_batch` on a paired complex a3m, `alphafold2_multimer_v3` | as 1, model has chains A and B, ipTM reported |
| 4 | `single_sequence` | `colabfold_batch chainA.fasta --msa-mode single_sequence` | model written (pLDDT reported, not checked) |
| 5 | `colabfold_search` | `colabfold_search` against local UniRef30 only *(database test)* | an a3m with more than one sequence |
| 6 | `msa_server` | `colabfold_batch chainA.fasta` with MSAs from the public ColabFold server *(network test)* | as 1 |

Tests 1-4 take a few minutes each.

## Settings

Set these in the environment when you submit, e.g. `MIN_PLDDT=60 sbatch ...`.

| Variable | Default | Meaning |
|----------|---------|---------|
| `COLABFOLD_DATA_DIR` | `/scratch/references/colabfold_jun2026/database` | Passed to `--data`; must contain `params/` with the AlphaFold2 weights |
| `COLABFOLD_DB_DIR` | same as `COLABFOLD_DATA_DIR` | Database directory for test 5 |
| `COLABFOLD_UNIREF_DB` | `uniref30_2302_db` | UniRef30 database name inside `COLABFOLD_DB_DIR` (test 5) |
| `MIN_PLDDT` | `70` | Lowest acceptable mean pLDDT (0-100) of the rank-1 model |
| `SINGULARITY_MODULE` | `singularity/3.11.4-nompi` | Module that provides `singularity` |
| `SINGULARITY_ARGS` | *(empty)* | Extra `singularity exec` options, e.g. `--bind /software` |
| `OUTPUT_ROOT` | `$MYSCRATCH/gpu_biology_tests` | Where test outputs go |
| `SUMMARY_SBATCH_ARGS` | `--nodes=1 --gres=gpu:1 --time=00:05:00` | Resources for the summary job |

`build.sh` settings: `BUILD_DIR` (default `$MYSCRATCH/gpu_biology_builds`), `PODMAN_JOBS` (default `4`), `KEEP_OCI_ARCHIVE=1` to keep the intermediate `.tar`.

## Inputs

- `chainA.a3m`: 256-sequence MSA for chain A.
- `heterodimer_AB_colabfold.a3m`: chains A and B in ColabFold's complex a3m format (128 paired rows, plus each chain's unpaired rows), written with ColabFold's own `msa_to_str`.
- `chainA.fasta`: the chain A sequence.

The MSAs are cut down from the Boltz-2 example inputs in the GPU_biology repository (`boltz2/v2.2.1/testing/inputs`).
