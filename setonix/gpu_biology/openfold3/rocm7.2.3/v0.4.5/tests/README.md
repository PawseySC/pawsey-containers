# OpenFold3 v0.4.5 (ROCm 7.2.3): container tests

## 1. Build (podman build node)

```bash
./build.sh
```

This builds `../Dockerfile` with podman, converts the image to `$MYSCRATCH/gpu_biology_builds/openfold3_v0.4.5-rocm7.2.3.sif`, and runs quick checks inside it (imports, ROCm PyTorch, installed `openfold3` is 0.4.5, `run_openfold predict --help`, image title label). It ends with `OVERALL: PASS` or `OVERALL: FAIL`.

## 2. Test on the GPU partition (Setonix)

The OpenFold3 checkpoint is not in the container, so point `OF3_CHECKPOINT` at your copy:

```bash
OF3_CHECKPOINT=/path/to/of3_checkpoint.pt \
  sbatch --account=<project>-gpu openfold3_tests.sh /path/to/openfold3_v0.4.5-rocm7.2.3.sif
```

Each test runs as one array task on one GCD. When they have all finished, a summary job writes `openfold3-tests_<jobid>_summary.out` in the directory you submitted from, with one PASS/FAIL/SKIP line per test. Each test's full log is in `openfold3-tests_<jobid>_<test#>.out`, and its outputs are in `$MYSCRATCH/gpu_biology_tests/openfold3/<jobid>/`.

Test 7 fetches MSAs from the public ColabFold server, which needs internet access from the compute node, so it only runs if you ask for it:

```bash
OF3_CHECKPOINT=... sbatch --account=<project>-gpu --array=0-7 openfold3_tests.sh IMAGE
```

## What is tested

Tests 1-6 run `run_openfold predict --use-msa-server=False --use-templates=False --num-diffusion-samples 1`. The protein is 112 residues (chain A), with a 116-residue partner (chain B) in the dimer test. Except in test 6, OpenFold3 uses its Triton kernels, which are the default on ROCm.

| # | Test | Input | Passes when |
|---|------|-------|-------------|
| 0 | `gpu_check` | PyTorch matrix multiply on the GPU | PyTorch is a ROCm build, sees the GPU, result is correct |
| 1 | `protein_msa` | chain A with a precomputed MSA | model and aggregated confidences written, avg pLDDT ≥ `MIN_PLDDT` |
| 2 | `heterodimer` | chains A + B with precomputed main and paired MSAs | as 1 (ipTM reported) |
| 3 | `protein_ligand` | chain A + ATP (CCD code) + theophylline (SMILES) | as 1, plus ATP in the model |
| 4 | `protein_dna` | chain A + 12-bp DNA duplex | as 1 |
| 5 | `no_msa` | chain A with no MSA | model written (pLDDT reported, not checked) |
| 6 | `no_triton_kernels` | as 1, with `--runner-yaml no_triton.yml` (Triton kernels off) | as 1 |
| 7 | `msa_server` | chain A, `--use-msa-server=True` *(network test)* | as 1 |

Each test takes a few minutes. The first Triton run on a node also compiles kernels into `~/.triton/cache`.

## Settings

Set these in the environment when you submit, e.g. `MIN_PLDDT=60 sbatch ...`.

| Variable | Default | Meaning |
|----------|---------|---------|
| `OF3_CHECKPOINT` | *(none; required)* | OpenFold3 checkpoint (`.pt` file, or checkpoint directory) passed to `--inference-ckpt-path` |
| `MIN_PLDDT` | `70` | Lowest acceptable `avg_plddt` (0-100) |
| `NUM_DIFFUSION_SAMPLES` | `1` | `--num-diffusion-samples` |
| `SINGULARITY_MODULE` | `singularity/3.11.4-nompi` | Module that provides `singularity` |
| `SINGULARITY_ARGS` | *(empty)* | Extra `singularity exec` options, e.g. `--bind /software` |
| `OUTPUT_ROOT` | `$MYSCRATCH/gpu_biology_tests` | Where test outputs go |
| `SUMMARY_SBATCH_ARGS` | `--nodes=1 --gres=gpu:1 --time=00:05:00` | Resources for the summary job |

`build.sh` settings: `BUILD_DIR` (default `$MYSCRATCH/gpu_biology_builds`), `PODMAN_JOBS` (default `4`), `KEEP_OCI_ARCHIVE=1` to keep the intermediate `.tar`.

## Inputs

- `*.json`: OpenFold3 query files, one per test.
- `msas/chainA/`, `msas/chainB/`: `colabfold_main.a3m` (256 sequences) and `colabfold_paired.a3m` (128 sequences; row *n* of A pairs with row *n* of B). These file names match OpenFold3's built-in ColabFold MSA settings, so no runner YAML is needed.
- `no_triton.yml`: runner YAML that turns off the Triton kernels.

The MSAs are cut down from the Boltz-2 example inputs in the GPU_biology repository (`boltz2/v2.2.1/testing/inputs`).
