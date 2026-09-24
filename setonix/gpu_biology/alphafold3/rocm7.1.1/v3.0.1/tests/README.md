# AlphaFold3 v3.0.1 (ROCm 7.1.1): container tests

## 1. Build (podman build node)

```bash
./build.sh
```

This builds `../Dockerfile` with podman, converts the image to `$MYSCRATCH/gpu_biology_builds/alphafold3_v3.0.1-rocm7.1.1.sif`, and runs quick checks inside it (imports, `run_alphafold.py --help`, AMD patch applied, HMMER tools and `jq` on `PATH`, image title label). It ends with `OVERALL: PASS` or `OVERALL: FAIL`.

## 2. Test on the GPU partition (Setonix)

The AlphaFold3 weights are not distributed with the container, so point `AF3_MODEL_DIR` at your copy:

```bash
AF3_MODEL_DIR=/path/to/af3_weights \
  sbatch --account=<project>-gpu alphafold3_tests.sh /path/to/alphafold3_v3.0.1-rocm7.1.1.sif
```

Each test runs as one array task on one GCD. When they have all finished, a summary job writes `alphafold3-tests_<jobid>_summary.out` in the directory you submitted from, with one PASS/FAIL/SKIP line per test. Each test's full log is in `alphafold3-tests_<jobid>_<test#>.out`, and its outputs are in `$MYSCRATCH/gpu_biology_tests/alphafold3/<jobid>/`.

Test 7 runs the data pipeline against the reference databases (about an hour) and only runs if you ask for it:

```bash
AF3_MODEL_DIR=... AF3_DB_DIR=/path/to/af3_databases \
  sbatch --account=<project>-gpu --array=0-7 --time=02:00:00 alphafold3_tests.sh IMAGE
```

## What is tested

Tests 1-6 run inference only (`--norun_data_pipeline`) from JSON inputs that already contain their MSAs, with `--num_recycles=3 --num_diffusion_samples=1`. The protein is 112 residues (chain A), with a 116-residue partner (chain B) in the dimer test.

| # | Test | Input | Passes when |
|---|------|-------|-------------|
| 0 | `gpu_check` | JAX matrix multiply on the GPU | JAX reports a GPU device and the result is correct |
| 1 | `protein_monomer` | chain A with MSA; default Triton flash attention (uses the AMD patches) | model, confidences written; mean pLDDT ≥ `MIN_PLDDT` |
| 2 | `flash_attention_xla` | same as 1 with `--flash_attention_implementation=xla` | as 1 |
| 3 | `heterodimer` | chains A + B with paired and unpaired MSAs | as 1, plus an ipTM score |
| 4 | `protein_ligand_ion` | chain A + ATP (CCD code) + Mg²⁺ | as 1, plus ATP in the model |
| 5 | `protein_dna` | chain A + 12-bp DNA duplex | as 1 |
| 6 | `rna_ligand` | 33-nt theophylline RNA aptamer + theophylline as SMILES, no MSA | model and confidences written (pLDDT reported, not checked) |
| 7 | `data_pipeline` | chain A sequence only, `--norun_inference` *(database test)* | `*_data.json` written with a non-empty MSA |

Tests 1-6 take a few minutes each, most of it JAX compilation.

## Settings

Set these in the environment when you submit, e.g. `MIN_PLDDT=60 sbatch ...`.

| Variable | Default | Meaning |
|----------|---------|---------|
| `AF3_MODEL_DIR` | *(none; required)* | Directory containing the AlphaFold3 weights (`af3.bin`) |
| `AF3_DB_DIR` | *(none)* | AlphaFold3 database directory, needed for test 7 only |
| `MIN_PLDDT` | `70` | Lowest acceptable mean atom pLDDT (0-100) |
| `NUM_RECYCLES` | `3` | `--num_recycles` for tests 1-6 |
| `NUM_DIFFUSION_SAMPLES` | `1` | `--num_diffusion_samples` for tests 1-6 |
| `SINGULARITY_MODULE` | `singularity/3.11.4-nompi` | Module that provides `singularity` |
| `SINGULARITY_ARGS` | *(empty)* | Extra `singularity exec` options, e.g. `--bind /software` |
| `OUTPUT_ROOT` | `$MYSCRATCH/gpu_biology_tests` | Where test outputs go |
| `SUMMARY_SBATCH_ARGS` | `--nodes=1 --gres=gpu:1 --time=00:05:00` | Resources for the summary job |

`build.sh` settings: `BUILD_DIR` (default `$MYSCRATCH/gpu_biology_builds`), `PODMAN_JOBS` (default `4`), `KEEP_OCI_ARCHIVE=1` to keep the intermediate `.tar`.

## Inputs

`inputs/*.json` are AlphaFold3 input files (`dialect: alphafold3`, `version: 3`). The protein MSAs are 256-sequence alignments cut down from the Boltz-2 example inputs in the GPU_biology repository (`boltz2/v2.2.1/testing/inputs`). In `heterodimer.json`, row *n* of chain A's `pairedMsa` pairs with row *n* of chain B's. `sequence_only.json` has no MSA, for the data pipeline test.
