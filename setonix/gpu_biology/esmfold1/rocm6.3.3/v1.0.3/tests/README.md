# ESMFold v1.0.3 (ROCm 6.3.3): container tests

## 1. Build (podman build node)

```bash
./build.sh
```

This builds `../Dockerfile` with podman, converts the image to `$MYSCRATCH/gpu_biology_builds/esmfold1_v1.0.3-rocm6.3.3.sif`, and runs quick checks inside it (imports, ROCm PyTorch, `esm-fold`/`esm-extract --help`, alignment tools on `PATH`, image title label). It ends with `OVERALL: PASS` or `OVERALL: FAIL`.

## 2. Test on the GPU partition (Setonix)

```bash
sbatch --account=<project>-gpu esmfold1_tests.sh /path/to/esmfold1_v1.0.3-rocm6.3.3.sif
```

Each test runs as one array task on one GCD. When they have all finished, a summary job writes `esmfold1-tests_<jobid>_summary.out` in the directory you submitted from, with one PASS/FAIL/SKIP line per test. Each test's full log is in `esmfold1-tests_<jobid>_<test#>.out`, and its outputs are in `$MYSCRATCH/gpu_biology_tests/esmfold1/<jobid>/`.

## What is tested

| # | Test | What runs | Passes when |
|---|------|-----------|-------------|
| 0 | `gpu_check` | PyTorch matrix multiply on the GPU; `import openfold` | PyTorch is a ROCm build, sees the GPU, result is correct |
| 1 | `monomer` | `esm-fold` on ubiquitin (76 residues) | PDB written, mean pLDDT ≥ `MIN_PLDDT` |
| 2 | `multimer` | `esm-fold` on a 112 + 116 residue heterodimer given as `A:B` | PDB has chains A and B |
| 3 | `batch_chunked` | `esm-fold` on 4 sequences (10-116 residues) with `--chunk-size 32 --max-tokens-per-batch 256` | all 4 PDBs written, ubiquitin pLDDT ≥ `MIN_PLDDT` |
| 4 | `esm2_embeddings` | `esm-extract` with `ESM_EMBEDDING_MODEL`, `--include mean per_tok` | embeddings written and finite. **SKIP** if that model's weights are not in `ESM_MODELS_DIR` |
| 5 | `openmm_hip` | `python -m openmm.testInstallation` | the HIP platform computes forces |

Each test takes a few minutes, mostly loading the 3B-parameter model.

## Settings

Set these in the environment when you submit, e.g. `MIN_PLDDT=60 sbatch ...`.

| Variable | Default | Meaning |
|----------|---------|---------|
| `ESM_MODELS_DIR` | `/scratch/references/esmfold/models` | Used as `TORCH_HOME`; must contain `hub/checkpoints/esmfold_3B_v1.pt` and the ESM-2 3B weights |
| `ESM_EMBEDDING_MODEL` | `esm2_t36_3B_UR50D` | ESM-2 model used by test 4 |
| `MIN_PLDDT` | `70` | Lowest acceptable mean pLDDT (0-100) |
| `SINGULARITY_MODULE` | `singularity/3.11.4-nompi` | Module that provides `singularity` |
| `SINGULARITY_ARGS` | *(empty)* | Extra `singularity exec` options, e.g. `--bind /software` |
| `OUTPUT_ROOT` | `$MYSCRATCH/gpu_biology_tests` | Where test outputs go |
| `SUMMARY_SBATCH_ARGS` | `--nodes=1 --gres=gpu:1 --time=00:05:00` | Resources for the summary job |

`build.sh` settings: `BUILD_DIR` (default `$MYSCRATCH/gpu_biology_builds`), `PODMAN_JOBS` (default `4`), `KEEP_OCI_ARCHIVE=1` to keep the intermediate `.tar`.

## Inputs

- `ubiquitin.fasta`: human ubiquitin, which ESMFold predicts with high confidence.
- `heterodimer_AB.fasta`: chains A and B joined with `:` (ESMFold's multimer syntax).
- `batch.fasta`: ubiquitin, chain A, chain B and a 10-residue peptide.
- `chainA.fasta`: chain A only, for the embeddings test.
