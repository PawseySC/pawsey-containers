# Boltz-2 v2.2.1 (ROCm 6.4.1): container tests

## 1. Build (podman build node)

```bash
./build.sh
```

This builds `../Dockerfile` with podman, converts the image to `$MYSCRATCH/gpu_biology_builds/boltz2_v2.2.1-rocm6.4.1.sif`, and runs quick checks inside it (imports, ROCm PyTorch, `boltz predict --help`, image title label). It ends with `OVERALL: PASS` or `OVERALL: FAIL`.

## 2. Test on the GPU partition (Setonix)

```bash
sbatch --account=<project>-gpu boltz2_tests.sh /path/to/boltz2_v2.2.1-rocm6.4.1.sif
```

Each test runs as one array task on one GCD. When they have all finished, a summary job writes `boltz2-tests_<jobid>_summary.out` in the directory you submitted from, with one PASS/FAIL/SKIP line per test. Each test's full log is in `boltz2-tests_<jobid>_<test#>.out`, and its outputs are in `$MYSCRATCH/gpu_biology_tests/boltz2/<jobid>/`.

Test 6 fetches an MSA from the public ColabFold server, which needs internet access from the compute node, so it only runs if you ask for it:

```bash
sbatch --account=<project>-gpu --array=0-6 boltz2_tests.sh IMAGE
```

## What is tested

Every run is `boltz predict <input>.yaml --no_kernels --seed 0` with default sampling settings. `--no_kernels` is needed because the cuEquivariance kernels are NVIDIA-only. The protein is 112 residues (chain A), with a 116-residue partner (chain B) in the dimer test.

| # | Test | Input | Passes when |
|---|------|-------|-------------|
| 0 | `gpu_check` | PyTorch matrix multiply on the GPU | PyTorch is a ROCm build, sees the GPU, result is correct |
| 1 | `protein_msa` | chain A with a precomputed MSA (CSV) | model and confidence written, pLDDT ≥ `MIN_PLDDT` |
| 2 | `heterodimer` | chains A + B, MSAs paired by CSV key | as 1 (ipTM reported) |
| 3 | `protein_ligand_affinity` | chain A + theophylline (SMILES), `properties: affinity` | as 1, plus an `affinity_pred_value` |
| 4 | `protein_dna` | chain A + 12-bp DNA duplex | as 1 |
| 5 | `single_sequence` | chain A with `msa: empty`, `--use_potentials` | model written (pLDDT reported, not checked) |
| 6 | `msa_server` | chain A, `--use_msa_server` *(network test)* | as 1 |

Each test takes a few minutes.

## Settings

Set these in the environment when you submit, e.g. `MIN_PLDDT=60 sbatch ...`.

| Variable | Default | Meaning |
|----------|---------|---------|
| `BOLTZ_CACHE` | `/scratch/references/boltz` | Passed to `--cache`; must contain `boltz2_conf.ckpt`, `boltz2_aff.ckpt` and the extracted `mols/` directory |
| `MIN_PLDDT` | `70` | Lowest acceptable complex pLDDT (reported by Boltz on 0-1, compared here on 0-100) |
| `SINGULARITY_MODULE` | `singularity/3.11.4-nompi` | Module that provides `singularity` |
| `SINGULARITY_ARGS` | *(empty)* | Extra `singularity exec` options, e.g. `--bind /software` |
| `OUTPUT_ROOT` | `$MYSCRATCH/gpu_biology_tests` | Where test outputs go |
| `SUMMARY_SBATCH_ARGS` | `--nodes=1 --gres=gpu:1 --time=00:05:00` | Resources for the summary job |

`build.sh` settings: `BUILD_DIR` (default `$MYSCRATCH/gpu_biology_builds`), `PODMAN_JOBS` (default `4`), `KEEP_OCI_ARCHIVE=1` to keep the intermediate `.tar`.

## Inputs

- `*.yaml`: Boltz input files, one per test.
- `chainA.csv`, `chainB.csv`: 256-sequence MSAs in Boltz CSV format. Rows with the same `key` in both files are paired and `-1` means unpaired.

The sequences are Boltz's own multimer example. The MSAs are cut down from the example inputs in the GPU_biology repository (`boltz2/v2.2.1/testing/inputs`).
