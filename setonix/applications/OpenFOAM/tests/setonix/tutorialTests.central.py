#!/usr/bin/env python3
"""Regression checks for central tutorial workflows; no real modules, containers or Slurm."""

import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[2]
SCRIPTS = Path(__file__).resolve().parent / "tutorial"
LAUNCHER = Path(__file__).resolve().with_name("openfoamTutorialTestLauncher.central.sh")
VERSIONS = [
    "openfoam/v2012", "openfoam/v2206", "openfoam/v2212",
    "openfoam/v2406", "openfoam/v2412", "openfoam/v2606",
    "openfoam-org/10", "openfoam-org/12", "openfoam-org/14",
]

MOCK = r'''#!/usr/bin/env python3
import json, os, pathlib, subprocess, sys
name = pathlib.Path(sys.argv[0]).name
args = sys.argv[1:]
root = pathlib.Path(os.environ["MOCK_ROOT"])
with (root / "calls.jsonl").open("a") as stream:
    stream.write(json.dumps([name, args]) + "\n")
if name in ("openfoam-exec", "openfoam-org-exec"):
    sys.exit(subprocess.call(args))
if name == "singularity":
    if args == ["--version"]:
        print("singularity mock")
        sys.exit(0)
    assert args[0] == "exec", args
    sys.exit(subprocess.call(args[2:]))
if name == "srun":
    while args and args[0].startswith("-"):
        option = args.pop(0)
        if option in ("-N", "-n", "-c", "--nodes", "--ntasks", "--cpus-per-task"):
            args.pop(0)
    sys.exit(subprocess.call(args))
if name == "foamDictionary":
    path = pathlib.Path(args[0])
    data = json.loads(path.read_text())
    entry = args[args.index("-entry") + 1]
    if "-set" in args:
        data[entry] = args[args.index("-set") + 1]
        path.write_text(json.dumps(data))
    else:
        print(data[entry])
    sys.exit(0)
if name == "checkMesh":
    if os.environ.get("MOCK_FAIL") == name:
        print("deliberate mesh failure")
        sys.exit(7)
    print("Mesh OK")
elif name == "decomposePar":
    for group in ("processors4_0-1", "processors4_2-3"):
        pathlib.Path(group).mkdir(exist_ok=True)
elif name == "pimpleFoam":
    if os.environ.get("MOCK_FAIL") == name:
        print("deliberate solver failure")
        sys.exit(8)
    print("Time = " + os.environ.get("MOCK_FINAL_TIME", "100"))
    print("Solving for Ux, Initial residual = " + os.environ.get("MOCK_RESIDUAL", "0.001") + ", Final residual = 1e-08")
    print("ExecutionTime = " + os.environ.get("MOCK_EXECUTION_TIME", "20") + " s  ClockTime = 20 s")
elif name == "sbatch":
    index = next(i for i, a in enumerate(args) if a.endswith(".central.slurm.sh"))
    script, stage_args = args[index], args[index + 1:]
    job_id = 101 if "preFoam" in script else 102
    env = os.environ.copy()
    def option(prefix):
        return next(a.split("=", 1)[1] for a in args[:index] if a.startswith(prefix + "="))
    env.update(SLURM_JOB_NUM_NODES=option("--nodes"),
               SLURM_NTASKS=option("--ntasks"),
               SLURM_CPUS_PER_TASK=option("--cpus-per-task"),
               SLURM_JOB_ID=str(job_id))
    output = option("--output").replace("%j", str(job_id))
    with open(output, "w") as stream:
        status = subprocess.call(["bash", script] + stage_args, env=env,
                                 stdout=stream, stderr=subprocess.STDOUT)
    (root / ("job-" + str(job_id))).write_text(str(status))
    print(job_id)
elif name == "sacct":
    job_id = next(a.split("=", 1)[1] for a in args if a.startswith("--jobs="))
    status = (root / ("job-" + job_id)).read_text()
    print(job_id + "|" + ("COMPLETED" if status == "0" else "FAILED") + "|" + status + ":0")
elif name in ("blockMesh", "renumberMesh", "squeue"):
    pass
else:
    raise AssertionError("unexpected mock command: " + name)
'''


class CentralTutorialTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="openfoam central-")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.bin = self.root / "bin"
        self.bin.mkdir()
        mock = self.bin / "mock"
        mock.write_text(MOCK)
        mock.chmod(0o755)
        for name in (
            "singularity", "openfoam-exec", "openfoam-org-exec", "srun",
            "foamDictionary", "blockMesh", "renumberMesh", "checkMesh",
            "decomposePar", "pimpleFoam", "sbatch", "squeue", "sacct",
        ):
            (self.bin / name).symlink_to(mock)
        self.tutorials = self.root / "tutorials"
        for case in ("channel395", "periodicPlaneChannel"):
            source = self.tutorials / case
            for directory in ("system", "constant", "0.orig"):
                (source / directory).mkdir(parents=True)
            for dictionary in ("controlDict", "decomposeParDict"):
                (source / "system" / dictionary).write_text("{}")
        self.image = self.root / "fixture.sif"
        self.image.touch()
        init = self.root / "init.sh"
        init.write_text(
            'export PATH="$MOCK_ROOT/bin:$PATH"\n'
            'module() {\n'
            '  export WM_PROJECT_VERSION="$MOCK_VERSION"\n'
            '  export FOAM_TUTORIALS="$MOCK_ROOT/tutorials"\n'
            '  export SINGULARITY_CONTAINER="$MOCK_ROOT/fixture.sif"\n'
            '  return 0\n'
            '}\n'
        )
        self.env = os.environ.copy()
        self.env.update(
            BASH_ENV=str(init), MOCK_ROOT=str(self.root), MOCK_VERSION="v2606",
            MYSCRATCH=str(self.root / "scratch"), TMPDIR=str(self.root),
            POLL_INTERVAL_SECONDS="0",
        )
        self.env.pop("MOCK_FAIL", None)
        self.env["PATH"] = str(self.bin) + os.pathsep + self.env["PATH"]

    def config(self, version):
        self.env["MOCK_VERSION"] = version.split("/")[1]
        return ROOT / version / "buildAndValidationConfig/openfoamBuildAndValidation.central.config"

    def invoke(self, script, *args, status=0):
        result = subprocess.run(
            ["bash", str(script), *map(str, args)], env=self.env,
            cwd=self.root, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
            universal_newlines=True,
        )
        self.assertEqual(result.returncode, status, result.stdout + result.stderr)
        return result

    def calls(self):
        path = self.root / "calls.jsonl"
        return [json.loads(line) for line in path.read_text().splitlines()] if path.exists() else []

    def stages(self, version, runtime):
        config = self.config(version)
        mode = ["--image", self.image] if runtime == "image" else ["--" + runtime]
        tag = version.replace("/", "-") + "-" + runtime
        work = self.root / tag
        artifacts = self.root / (tag + "-artifacts")
        common = ["--config", config, *mode, "--work-root", work,
                  "--test-artifacts-dir", artifacts]
        self.invoke(SCRIPTS / "extractCase.central.sh", *common)
        self.env.update(SLURM_JOB_NUM_NODES="1", SLURM_NTASKS="1", SLURM_CPUS_PER_TASK="1")
        self.invoke(SCRIPTS / "preFoam.central.slurm.sh", *common)
        self.env.update(SLURM_JOB_NUM_NODES="2", SLURM_NTASKS="4", SLURM_CPUS_PER_TASK="1")
        self.invoke(SCRIPTS / "runFoam.central.slurm.sh", *common)
        return common, work, artifacts

    def test_all_versions_and_runtime_routes(self):
        for version in VERSIONS:
            for runtime in ("bare-metal", "shpc", "image"):
                with self.subTest(version=version, runtime=runtime):
                    calls_file = self.root / "calls.jsonl"
                    if calls_file.exists():
                        calls_file.unlink()
                    _, work, artifacts = self.stages(version, runtime)
                    case = "periodicPlaneChannel" if version.startswith("openfoam/") and version != "openfoam/v2012" else "channel395"
                    dictionaries = json.loads((work / "run" / case / "system/decomposeParDict").read_text())
                    entry = "simple/n" if version == "openfoam-org/14" else "simpleCoeffs/n" if version.startswith("openfoam-org/") else "coeffs/n"
                    self.assertEqual(dictionaries[entry].replace(" ", ""), "(122)")
                    tool_calls = [(name, args) for name, args in self.calls()
                                  if name in ("blockMesh", "renumberMesh", "checkMesh", "decomposePar", "pimpleFoam")]
                    names = [name for name, _ in tool_calls]
                    expected = ["blockMesh"]
                    if case == "periodicPlaneChannel":
                        expected += ["renumberMesh"]
                    expected += ["checkMesh", "decomposePar", "pimpleFoam"]
                    self.assertEqual(names, expected)
                    flag = "-cellProc" if version in ("openfoam-org/12", "openfoam-org/14") else "-cellDist"
                    self.assertIn(("decomposePar", [flag, "-force"]), tool_calls)
                    for stage in ("extractCase", "preFoam", "runFoam"):
                        self.assertEqual((artifacts / (stage + ".status.txt")).read_text().strip(), "SUCCESS")

    def test_launcher_resources_dependencies_and_isolation(self):
        source = self.config("openfoam/v2606")
        recipe = self.root / "recipe"
        config_dir = recipe / "buildAndValidationConfig"
        config_dir.mkdir(parents=True)
        shutil.copyfile(source, config_dir / source.name)
        for runtime in ("bare-metal", "shpc", "image"):
            with self.subTest(runtime=runtime):
                mode = ["--image", self.image] if runtime == "image" else ["--" + runtime]
                self.invoke(LAUNCHER, "--recipe-dir", recipe, *mode)
                submissions = [args for name, args in self.calls() if name == "sbatch"][-2:]
                self.assertEqual(len(submissions), 2)
                self.assertIn("--nodes=1", submissions[0])
                self.assertIn("--ntasks=1", submissions[0])
                self.assertIn("--nodes=2", submissions[1])
                self.assertIn("--ntasks=4", submissions[1])
                self.assertIn("--dependency=afterok:101", submissions[1])
                self.assertIn("--kill-on-invalid-dep=yes", submissions[1])
                for args in submissions:
                    self.assertTrue(any(".central.slurm.sh" in arg for arg in args))
                    self.assertIn(str(config_dir / source.name), args)
        self.assertTrue((recipe / "artifacts/tests/tutorial-central/latest").is_symlink())
        self.assertFalse((recipe / "artifacts/tests/tutorial").exists())
        self.assertFalse((self.root / "scratch/OpenFOAM-functional-tests").exists())

    def test_failures_do_not_pass(self):
        common, _, artifacts = self.stages("openfoam/v2606", "bare-metal")
        self.env["MOCK_FAIL"] = "checkMesh"
        self.env.update(SLURM_JOB_NUM_NODES="1", SLURM_NTASKS="1")
        self.invoke(SCRIPTS / "preFoam.central.slurm.sh", *common, status=1)
        self.assertEqual((artifacts / "preFoam.status.txt").read_text().strip(), "FAILED")
        self.env["MOCK_FAIL"] = "pimpleFoam"
        self.env.update(SLURM_JOB_NUM_NODES="2", SLURM_NTASKS="4")
        self.invoke(SCRIPTS / "runFoam.central.slurm.sh", *common, status=1)
        self.assertEqual((artifacts / "runFoam.status.txt").read_text().strip(), "FAILED")

    def test_invalid_config_rejected_before_runtime(self):
        config = self.root / "invalid.central.config"
        config.write_text(self.config("openfoam/v2606").read_text() +
                          "\nTUTORIAL_PRE_mesh=(unknown_operation)\n")
        result = self.invoke(
            LAUNCHER, "--config", config, "--artifacts-dir", "results",
            "--bare-metal", "--submit-only", status=1,
        )
        self.assertIn("ERROR", result.stdout + result.stderr)
        self.assertEqual(self.calls(), [])
        self.assertFalse((self.root / "results").exists())

    def test_numerical_assertions_and_performance_warning(self):
        common, _, artifacts = self.stages("openfoam/v2606", "bare-metal")
        for setting, value in (("MOCK_FINAL_TIME", "99"), ("MOCK_RESIDUAL", "0.012")):
            with self.subTest(setting=setting):
                self.env[setting] = value
                self.invoke(SCRIPTS / "runFoam.central.slurm.sh", *common, status=1)
                self.assertEqual((artifacts / "runFoam.status.txt").read_text().strip(), "FAILED")
                del self.env[setting]
        self.env["MOCK_EXECUTION_TIME"] = "50"
        result = self.invoke(SCRIPTS / "runFoam.central.slurm.sh", *common)
        self.assertIn("WARNING", result.stdout + result.stderr)
        self.assertEqual((artifacts / "runFoam.status.txt").read_text().strip(), "SUCCESS")

    def test_standalone_recipe_and_overwrite_protection(self):
        source = self.config("openfoam/v2606")
        recipe = self.root / "recipe"
        config_dir = recipe / "buildAndValidationConfig"
        config_dir.mkdir(parents=True)
        shutil.copyfile(source, config_dir / source.name)
        self.invoke(SCRIPTS / "extractCase.central.sh", "--recipe-dir", recipe, "--bare-metal")
        self.invoke(SCRIPTS / "extractCase.central.sh", "--recipe-dir", recipe, "--bare-metal", status=1)
        self.invoke(SCRIPTS / "extractCase.central.sh", "--recipe-dir", recipe, "--bare-metal", "--overwrite")
        self.assertFalse((self.root / "scratch/OpenFOAM").exists())

    def test_no_fallback_to_original_configs(self):
        recipe = self.root / "recipe"
        directory = recipe / "buildAndValidationConfig"
        directory.mkdir(parents=True)
        original = ROOT / "openfoam/v2606/buildAndValidationConfig/openfoamBuildAndValidation.config"
        shutil.copyfile(original, directory / original.name)
        result = self.invoke(
            LAUNCHER, "--recipe-dir", recipe, "--bare-metal", "--submit-only", status=1,
        )
        self.assertIn("openfoamBuildAndValidation.central.config", result.stdout + result.stderr)
        self.assertEqual(self.calls(), [])
        self.assertFalse((recipe / "artifacts").exists())

    def test_relative_extraction_and_custom_launcher_locations(self):
        config = self.root / "custom.central.config"
        config.write_text(
            self.config("openfoam/v2606").read_text() +
            "\nTUTORIAL_EXTRACT_copy=(extract_relative periodicPlaneChannel)\n"
        )
        self.invoke(
            LAUNCHER, "--config", config, "--scripts-dir", SCRIPTS,
            "--artifacts-dir", "custom-results", "--bare-metal", "--submit-only",
        )
        latest = self.root / "custom-results/latest"
        self.assertTrue(latest.is_symlink())
        self.assertEqual((latest / "status.txt").read_text().strip(), "SUBMITTED")
        self.assertEqual(len([args for name, args in self.calls() if name == "sbatch"]), 2)

    def test_allocation_mismatch_prevents_solver(self):
        common, _, _ = self.stages("openfoam/v2606", "bare-metal")
        count = len([args for name, args in self.calls() if name == "pimpleFoam"])
        self.env["SLURM_JOB_NUM_NODES"] = "1"
        self.invoke(SCRIPTS / "runFoam.central.slurm.sh", *common, status=1)
        self.assertEqual(len([args for name, args in self.calls() if name == "pimpleFoam"]), count)

    def test_help_and_originals(self):
        originals = [ROOT / version / "buildAndValidationConfig/openfoamBuildAndValidation.config"
                     for version in VERSIONS]
        before = {p: hashlib.sha256(p.read_bytes()).digest() for p in originals}
        for script in [LAUNCHER, *(SCRIPTS / name for name in (
            "extractCase.central.sh", "preFoam.central.slurm.sh", "runFoam.central.slurm.sh",
        ))]:
            self.invoke(script, "--help")
            subprocess.run(["bash", "-n", str(script)], check=True)
        self.assertEqual(before, {p: hashlib.sha256(p.read_bytes()).digest() for p in originals})


if __name__ == "__main__":
    unittest.main(verbosity=2)
