# AlphaFold2 v2.3.2 (ROCm 6.2.4): container tests

## 1. Build (podman build node)

```bash
./build.sh
```

This builds `../Dockerfile` with podman, converts the image to `$MYSCRATCH/gpu_biology_builds/alphafold2_v2.3.2-rocm6.2.4.sif`, and runs quick checks inside it (imports, `--help` of each script, MSA tools on `PATH`, image title label). It ends with `OVERALL: PASS` or `OVERALL: FAIL`.

## 2. Test on the GPU partition (Setonix)

```bash
sbatch --account=<project>-gpu alphafold2_tests.sh /path/to/alphafold2_v2.3.2-rocm6.2.4.sif
```

Each test runs as one array task on one GCD. When they have all finished, a summary job writes `alphafold2-tests_<jobid>_summary.out` in the directory you submitted from, with one PASS/FAIL/SKIP line per test. Each test's full log is in `alphafold2-tests_<jobid>_<test#>.out`, and its outputs are in `$MYSCRATCH/gpu_biology_tests/alphafold2/<jobid>/`.

Tests 5 and 6 search the reference databases and take a few hours, so they only run if you ask for them:

```bash
sbatch --account=<project>-gpu --array=0-6 --time=04:00:00 alphafold2_tests.sh IMAGE
```

## What is tested

The input is a 112-residue protein (chain A) and a 116-residue partner (chain B) with small precomputed MSAs (256 sequences each, see `inputs/`). Tests 1-3 build `features.pkl` from these with `inputs/make_features.py` (no database search, empty template), then run the container's `run_predict.py` (the helper script used with nf-core/proteinfold). Relaxation is off in tests 1-3 and is tested on its own in test 4.

| # | Test | What runs | Passes when |
|---|------|-----------|-------------|
| 0 | `gpu_check` | JAX matrix multiply on the GPU | JAX reports a GPU device and the result is correct |
| 1 | `monomer` | `run_predict.py --model_preset=monomer` (5 models), chain A | `ranked_0.pdb` written, mean pLDDT ≥ `MIN_PLDDT` |
| 2 | `monomer_ptm` | `run_predict.py --model_preset=monomer_ptm --benchmark=True`, chain A | as above, plus benchmark timings in `timings.json` |
| 3 | `multimer` | `run_predict.py --model_preset=multimer` (5 models, 1 prediction each), chains A+B | `ranked_0.pdb` has chains A and B, iptm+ptm ranking, mean pLDDT ≥ `MIN_PLDDT` |
| 4 | `amber_relax` | AlphaFold's Amber relaxation (OpenMM) on AlphaFold's own relax test structure | relaxed PDB written and energy decreased |
| 5 | `msa_pipeline` | `run_msa.py`, reduced_dbs, chain A *(database test)* | `features.pkl` and `uniref90_hits.sto` written |
| 6 | `full_pipeline` | `run_alphafold.py` end to end, reduced_dbs, relaxes the best model *(database test)* | `ranked_0.pdb` and a relaxed model written, mean pLDDT ≥ `MIN_PLDDT` |

Tests 1-3 each take roughly 5-15 minutes, mostly compiling the 5 models. Tests 0 and 4 take a minute or two.

## Settings

Set these in the environment when you submit, e.g. `MIN_PLDDT=60 sbatch ...`.

| Variable | Default | Meaning |
|----------|---------|---------|
| `AF2_DATA_DIR` | `/scratch/references/alphafold_feb2024/databases` | AlphaFold2 data directory. Needs `params/` for all tests, plus the databases (`uniref90/`, `mgnify/`, `small_bfd/`, `pdb70/`, `pdb_mmcif/`) for tests 5-6 |
| `MIN_PLDDT` | `70` | Lowest acceptable mean pLDDT (0-100) of the top model |
| `RELAX_ON_GPU` | `True` | Relax on the GPU (`True`) or CPU (`False`) in tests 4 and 6 |
| `MAX_TEMPLATE_DATE` | `2023-05-14` | Template cut-off date for tests 5-6 |
| `SINGULARITY_MODULE` | `singularity/3.11.4-nompi` | Module that provides `singularity` |
| `SINGULARITY_ARGS` | *(empty)* | Extra `singularity exec` options, e.g. `--bind /software` |
| `OUTPUT_ROOT` | `$MYSCRATCH/gpu_biology_tests` | Where test outputs go |
| `SUMMARY_SBATCH_ARGS` | `--nodes=1 --gres=gpu:1 --time=00:05:00` | Resources for the summary job |

`build.sh` settings: `BUILD_DIR` (default `$MYSCRATCH/gpu_biology_builds`), `PODMAN_JOBS` (default `4`), `KEEP_OCI_ARCHIVE=1` to keep the intermediate `.tar`.

## Inputs

- `chainA.fasta`, `heterodimer_AB.fasta`: the query sequences.
- `chainA.a3m`, `chainB.a3m`: 256-sequence MSAs (query + 127 paired + 128 unpaired rows).
- `chainA_paired.a3m`, `chainB_paired.a3m`: the paired rows only. Row *n* of chain A pairs with row *n* of chain B, and a shared species tag in the headers (`..._P<n>`) lets AlphaFold pair them.
- `make_features.py`: builds `features.pkl` from these files.

The MSAs are cut down from the Boltz-2 example inputs in the GPU_biology repository (`boltz2/v2.2.1/testing/inputs`).
