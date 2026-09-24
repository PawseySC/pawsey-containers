# RFdiffusion v1.1.0 (ROCm 7.0.0, DGL 2.4.0): container tests

## 1. Build (podman build node)

```bash
./build.sh
```

This builds `../Dockerfile` with podman, converts the image to `$MYSCRATCH/gpu_biology_builds/rfdiffusion_v1.1.0-rocm7.0.0.sif`, and runs quick checks inside it (imports, ROCm PyTorch, all 9 model checkpoints present, Hydra config found by `run_inference.py`, example scaffolds unpacked, image title label). It ends with `OVERALL: PASS` or `OVERALL: FAIL`.

## 2. Test on the GPU partition (Setonix)

```bash
sbatch --account=<project>-gpu rfdiffusion_tests.sh /path/to/rfdiffusion_v1.1.0-rocm7.0.0.sif
```

Each test runs as one array task on one GCD. When they have all finished, a summary job writes `rfdiffusion-tests_<jobid>_summary.out` in the directory you submitted from, with one PASS/FAIL/SKIP line per test. Each test's full log is in `rfdiffusion-tests_<jobid>_<test#>.out`, and its outputs are in `$MYSCRATCH/gpu_biology_tests/rfdiffusion/<jobid>/`.

## What is tested

Each test makes one design with `run_inference.py` (`inference.num_designs=1`), using the example inputs and model weights inside the image. The tests follow the upstream `examples/design_*.sh` scripts, with smaller lengths. A test passes when the design `.pdb` and `.trb` are written. Where the shape is fixed, the residue count and chains are checked too.

| # | Test | Mode (model used) | Extra check |
|---|------|-------------------|-------------|
| 0 | `gpu_check` | PyTorch matrix multiply and a DGL message pass on the GPU; SE(3)-Transformer imports | — |
| 1 | `unconditional` | 60-residue monomer (Base) | 60 residues, chain A |
| 2 | `motif_scaffolding` | scaffold 5TPN residues A163-181 (Base) | — |
| 3 | `motif_inpaint_seq` | as 2, with part of the motif sequence masked (InpaintSeq) | — |
| 4 | `partial_diffusion` | re-diffuse 2KL8 with `partial_T=10` (Base) | 79 residues, chain A |
| 5 | `binder_design` | 40-residue binder to the insulin receptor, with hotspots (Complex_base) | 190 residues, chains A + B |
| 6 | `fold_conditioned_binder` | binder from the bundled PPI scaffolds (Complex_Fold_base) | chains A + B |
| 7 | `symmetric_oligomer` | C3 oligomer, 3 × 30 residues, with oligomer contact potentials (`--config-name=symmetry`) | 90 residues, chains A-C |
| 8 | `enzyme_active_site` | scaffold the 5AN7 active site with a substrate potential (ActiveSite) | — |
| 9 | `cyclic_peptide_binder` | 12-18 residue cyclic peptide binding GABARAP (`inference.cyclic=True`) | chains A + B |

Each test takes a few minutes.

## Settings

Set these in the environment when you submit.

| Variable | Default | Meaning |
|----------|---------|---------|
| `SINGULARITY_MODULE` | `singularity/3.11.4-nompi` | Module that provides `singularity` |
| `SINGULARITY_ARGS` | *(empty)* | Extra `singularity exec` options, e.g. `--bind /software` |
| `OUTPUT_ROOT` | `$MYSCRATCH/gpu_biology_tests` | Where test outputs go |
| `SUMMARY_SBATCH_ARGS` | `--nodes=1 --gres=gpu:1 --time=00:05:00` | Resources for the summary job |

`build.sh` settings: `BUILD_DIR` (default `$MYSCRATCH/gpu_biology_builds`), `PODMAN_JOBS` (default `4`), `KEEP_OCI_ARCHIVE=1` to keep the intermediate `.tar`.

## Inputs

None: all inputs are the RFdiffusion examples bundled in the image under `/app/RFdiffusion/examples`.
