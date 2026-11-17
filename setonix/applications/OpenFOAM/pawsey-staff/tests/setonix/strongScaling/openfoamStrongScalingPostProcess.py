#!/usr/bin/env python3
"""
OpenFOAM strong-scaling postprocessor for Setonix campaign artifacts.

Design
======
The OpenFOAM jobs preserve raw solver output inside each campaign artifact
folder. This program treats those logs as the authoritative timing record and
keeps statistical choices outside the Slurm jobs. An analysis can therefore be
repeated with a different physical-time interval without rerunning OpenFOAM.

The postprocessor has four responsibilities:

1. discover completed runs in one campaign or in the case-level accumulated
   tree;
2. read topology metadata and parse ``Time``/``ExecutionTime`` records from
   the metadata-selected ``<solver>.log`` (with historical log fallbacks);
3. calculate per-run statistics over ``(start_time, end_time]``, where
   ``start_time`` is the new timing reference and the interval ending there is
   deliberately excluded; and
4. write reproducible CSV, text, PNG, and PDF products under an analysis
   directory named for the selected interval.

``scaling-metrics.env`` is retained only as topology and provenance metadata.
Its historical timing statistics are never reused. The program also maintains
the case-local accumulated symlink tree so multiple strong-scaling cases can
coexist without mixing results.

Log discovery uses SOLVER and RAW_LOG from each job's scaling-metrics.env.
Only files inside that job's artifact directory are read, even if RAW_LOG
contains a stale absolute path from a copied campaign. Conflicting metadata
raises an error instead of selecting an unrelated utility log. Historical jobs
without solver metadata retain pimpleFoam.log and runFoam.run.log fallbacks.
"""

from __future__ import annotations

# ============================================================================
# 1. Imports and regular expressions
#
# The standard library handles discovery, parsing, statistics, and CSV output.
# Matplotlib is imported only when a plot is produced so --help and validation
# do not require the plotting environment.
# ============================================================================

import argparse
import csv
import os
import re
import shutil
import statistics
import sys
from collections import defaultdict
from dataclasses import dataclass
from pathlib import Path

TIME_RE = re.compile(r"^(?:\d+:\s*)?Time\s*=\s*([-+0-9.eE]+)\s*$")
EXEC_RE = re.compile(r"^(?:\d+:\s*)?ExecutionTime\s*=\s*([-+0-9.eE]+)\s+s")
CAMPAIGN_RE = re.compile(r"^\d{8}T\d{6}[+-]\d{4}_.+")


# ============================================================================
# 2. Data models
#
# Compact dataclasses keep run metadata, raw timing records, and derived
# statistics explicit without passing positional shell fields between tools.
# ============================================================================

@dataclass(frozen=True)
class Run:
    job_dir: Path
    launch: str
    fork: str
    version: str
    runtime: str
    target_millions: str
    actual_cells: int
    nodes: int
    tasks_per_node: int
    cores: int
    cells_per_core: float


@dataclass(frozen=True)
class Result:
    run: Run
    source_log: str
    total_records: int
    durations: tuple[tuple[float, float], ...]  # (step end time, duration)

    @property
    def values(self) -> tuple[float, ...]:
        return tuple(duration for _, duration in self.durations)

    @property
    def mean(self) -> float:
        return statistics.fmean(self.values)

    @property
    def stddev(self) -> float:
        return statistics.stdev(self.values) if len(self.values) > 1 else 0.0


# ============================================================================
# 3. Command-line interface
#
# Both direct artifact analysis and recipe-based accumulated analysis are
# supported. Start and end times are mandatory to make every result auditable.
# ============================================================================

def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Regenerate OpenFOAM strong-scaling statistics from artifact logs."
    )
    source = parser.add_mutually_exclusive_group(required=True)
    source.add_argument("--artifacts-dir", type=Path)
    source.add_argument("--recipe-dir", "-r", type=Path)
    parser.add_argument("--case", required=True, dest="case_name")
    parser.add_argument("--runtime", choices=("shpc", "singularity", "bare-metal"))
    parser.add_argument("--cells-millions")
    parser.add_argument("--start-time", required=True, type=float)
    parser.add_argument("--end-time", required=True, type=float)
    parser.add_argument(
        "--point-mode",
        choices=("all-with-mean", "mean", "latest"),
        default="all-with-mean",
    )
    parser.add_argument("--single-launch-only", action="store_true")
    parser.add_argument("--rebuild-accumulated", action="store_true")
    args = parser.parse_args()
    if args.end_time <= args.start_time:
        parser.error("--end-time must be greater than --start-time")
    if not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._-]*", args.case_name):
        parser.error(f"invalid --case name: {args.case_name}")
    return args


# ============================================================================
# 4. Metadata and raw-log parsing
#
# Environment files provide stable run identity. Solver logs provide timing.
# A requested start time is a reference value: the first measured interval is
# from start_time to the next recorded physical time.
# ============================================================================

def read_env(path: Path) -> dict[str, str]:
    values: dict[str, str] = {}
    for line in path.read_text(errors="replace").splitlines():
        line = line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, value = line.split("=", 1)
        values[key] = value.strip().strip('"\'')
    return values


def locate_log(job_dir: Path) -> Path:
    """Select a portable solver log from job metadata, never arbitrary *.log files.

    SOLVER names the expected executable log. RAW_LOG may supply its original
    absolute path, but only its basename is used in the current artifact folder.
    Missing declared logs and conflicting declarations are errors. Historical
    jobs without declarations retain the original explicit fallback names.
    """
    metadata = read_env(job_dir / "scaling-metrics.env")
    solver = metadata.get("SOLVER", "").strip()
    raw_log = metadata.get("RAW_LOG", "").strip()

    # Validate executable identity before constructing a filename. This prevents
    # path components in metadata from redirecting discovery outside this job.
    if solver and not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9_.+-]*", solver):
        raise ValueError(f"invalid SOLVER value {solver!r} in {job_dir}")
    expected_name = f"{solver}.log" if solver else ""
    raw_name = Path(raw_log).name if raw_log else ""
    if raw_log and (not raw_name.endswith(".log") or raw_name == ".log"):
        raise ValueError(f"invalid RAW_LOG value {raw_log!r} in {job_dir}")
    if expected_name and raw_name and expected_name != raw_name:
        raise ValueError(
            f"conflicting SOLVER/RAW_LOG metadata in {job_dir}: "
            f"expected {expected_name}, recorded {raw_name}"
        )

    # Declared metadata is authoritative: do not silently substitute a wrapper
    # or another solver's log when the explicitly recorded log is missing.
    declared_name = expected_name or raw_name
    if declared_name:
        path = job_dir / declared_name
        if not path.is_file():
            raise ValueError(f"declared solver log {declared_name} not found in {job_dir}")
        if path.resolve().parent != job_dir.resolve():
            raise ValueError(f"solver log resolves outside its job artifact directory: {path}")
        return path

    # Compatibility is limited to known historical names. Utility logs such as
    # decomposePar.log and renumberMesh-parallel.log must never be guessed.
    for name in ("pimpleFoam.log", "runFoam.run.log"):
        path = job_dir / name
        if path.is_file():
            if path.resolve().parent != job_dir.resolve():
                raise ValueError(f"historical log resolves outside its job directory: {path}")
            return path
    raise ValueError(
        f"no solver log declared by SOLVER/RAW_LOG and no historical "
        f"pimpleFoam.log or runFoam.run.log in {job_dir}"
    )


def parse_records(path: Path) -> list[tuple[float, float]]:
    records: list[tuple[float, float]] = []
    pending_time: float | None = None
    for raw in path.read_text(errors="replace").splitlines():
        line = raw.strip()
        if match := TIME_RE.match(line):
            pending_time = float(match.group(1))
        elif pending_time is not None and (match := EXEC_RE.match(line)):
            records.append((pending_time, float(match.group(1))))
            pending_time = None
    if not records:
        raise ValueError(f"no complete Time/ExecutionTime records in {path}")
    return records


def select_interval(
    records: list[tuple[float, float]], start: float, end: float, path: Path
) -> tuple[tuple[float, float], ...]:
    tolerance = 1e-9 * max(1.0, abs(start), abs(end))

    def index_of(value: float) -> int | None:
        return next(
            (index for index, (time, _) in enumerate(records) if abs(time - value) <= tolerance),
            None,
        )

    start_index, end_index = index_of(start), index_of(end)
    if start_index is None or end_index is None:
        available = f"{records[0][0]:g}..{records[-1][0]:g}"
        raise ValueError(
            f"interval [{start:g}, {end:g}] is not exactly present in {path} "
            f"(available {available})"
        )
    if end_index <= start_index:
        raise ValueError(f"invalid record order in {path}")

    durations = tuple(
        (records[index][0], records[index][1] - records[index - 1][1])
        for index in range(start_index + 1, end_index + 1)
    )
    if any(duration <= 0 for _, duration in durations):
        raise ValueError(f"non-positive ExecutionTime difference in {path}")
    return durations


# ============================================================================
# 5. Artifact discovery and accumulated-tree maintenance
#
# Campaigns remain authoritative. The accumulated tree contains relative links
# grouped by runtime, mesh size, and topology; it can be rebuilt at any time.
# ============================================================================

def infer_launch(launch_dir: Path) -> tuple[str, str]:
    parts = launch_dir.name.split("_")
    if len(parts) < 3:
        raise ValueError(f"cannot infer runtime and mesh size from {launch_dir.name}")
    runtime, mesh = parts[-2], parts[-1]
    return runtime, mesh.removesuffix("M")


def campaign_dirs(case_root: Path) -> list[Path]:
    return sorted(
        path for path in case_root.iterdir() if path.is_dir() and CAMPAIGN_RE.match(path.name)
    )


def link_campaign(case_root: Path, launch_dir: Path) -> Path:
    runtime, cells_millions = infer_launch(launch_dir)
    accumulated = case_root / "accumulated" / runtime / f"{cells_millions}M"
    jobs_root = accumulated / "jobs"
    jobs_root.mkdir(parents=True, exist_ok=True)

    for job_dir in sorted((launch_dir / "jobs").glob("*")):
        if not (job_dir / "scaling-metrics.env").is_file():
            continue
        point_dir = jobs_root / job_dir.name
        point_dir.mkdir(parents=True, exist_ok=True)
        link = point_dir / launch_dir.name
        if link.exists() or link.is_symlink():
            link.unlink()
        link.symlink_to(Path(os.path.relpath(job_dir, point_dir)))
        latest = point_dir / "latest"
        if latest.exists() or latest.is_symlink():
            latest.unlink()
        latest.symlink_to(launch_dir.name)

    latest = case_root / "accumulated" / "latest"
    if latest.exists() or latest.is_symlink():
        latest.unlink()
    latest.symlink_to(Path(runtime) / f"{cells_millions}M")
    return accumulated


def rebuild_accumulated(case_root: Path) -> list[Path]:
    accumulated = case_root / "accumulated"
    if accumulated.exists():
        shutil.rmtree(accumulated)
    touched = {link_campaign(case_root, launch) for launch in campaign_dirs(case_root)}
    return sorted(touched)


def run_from_metrics(metrics_file: Path) -> Run:
    metadata = read_env(metrics_file)
    job_dir = metrics_file.resolve().parent
    launch = job_dir.parent.parent.name
    return Run(
        job_dir=job_dir,
        launch=launch,
        fork=metadata.get("OPENFOAM_FORK", "openfoam"),
        version=metadata.get("OPENFOAM_VERSION", "unknown"),
        runtime=metadata.get("RUNTIME_KEY", "unknown"),
        target_millions=metadata["TARGET_CELLS_MILLIONS"],
        actual_cells=int(metadata["ACTUAL_CELLS"]),
        nodes=int(metadata["NODES"]),
        tasks_per_node=int(metadata["TASKS_PER_NODE"]),
        cores=int(metadata["CORES"]),
        cells_per_core=float(metadata["CELLS_PER_CORE"]),
    )


def discover_runs(source_dir: Path, point_mode: str) -> list[Run]:
    runs: list[Run] = []
    for point_dir in sorted((source_dir / "jobs").glob("*")):
        direct = point_dir / "scaling-metrics.env"
        if direct.is_file():
            metrics_files = [direct]
        elif point_mode == "latest" and (point_dir / "latest/scaling-metrics.env").is_file():
            metrics_files = [point_dir / "latest/scaling-metrics.env"]
        else:
            metrics_files = sorted(
                path for path in point_dir.glob("*/scaling-metrics.env")
                if path.parent.name != "latest"
            )
        runs.extend(run_from_metrics(path) for path in metrics_files)
    if not runs:
        raise ValueError(f"no reusable runs found under {source_dir / 'jobs'}")
    return runs


# ============================================================================
# 6. Statistical analysis and durable output
#
# Every run must contain the exact requested interval. Per-step values are kept
# alongside summaries so later checks do not need to reverse engineer averages.
# ============================================================================

def analyse_run(run: Run, start: float, end: float) -> Result:
    log = locate_log(run.job_dir)
    records = parse_records(log)
    return Result(run, log.name, len(records), select_interval(records, start, end, log))


def interval_tag(value: float) -> str:
    return f"{value:g}".replace("-", "m").replace(".", "p")


def output_dir(source_dir: Path, start: float, end: float) -> Path:
    path = source_dir / "analyses" / f"time_{interval_tag(start)}_to_{interval_tag(end)}"
    path.mkdir(parents=True, exist_ok=True)
    return path


def write_outputs(
    results: list[Result], source_dir: Path, label: str, args: argparse.Namespace
) -> None:
    target = output_dir(source_dir, args.start_time, args.end_time)
    results = sorted(results, key=lambda item: (item.run.cores, item.run.launch))

    # Preserve the exact selected timing samples before aggregating repeated runs.
    with (target / "strong-scaling-step-times.csv").open("w", newline="") as stream:
        writer = csv.writer(stream)
        writer.writerow(("source_launch", "source_log", "cores", "nodes", "tasks_per_node", "step_end_time", "step_duration_s"))
        for result in results:
            for time, duration in result.durations:
                writer.writerow((result.run.launch, result.source_log, result.run.cores, result.run.nodes, result.run.tasks_per_node, f"{time:g}", f"{duration:.9f}"))

    # Record the analysis policy next to every generated product.
    (target / "analysis-info.env").write_text(
        "ANALYSIS_MODE=physical-time\n"
        f"START_TIME={args.start_time:g}\nEND_TIME={args.end_time:g}\n"
        "REFERENCE_POLICY=start-time-is-zero\n"
        f"INCLUDED_INTERVAL=({args.start_time:g},{args.end_time:g}]\n"
        "RAW_LOG_PREFERENCE=SOLVER.log,RAW_LOG-basename,historical-pimpleFoam.log,historical-runFoam.run.log\n"
    )

    fields = ("cores", "nodes", "tasks_per_node", "source_launch", "source_log", "actual_cells", "cells_per_core", "total_records", "stat_steps", "mean_step_time_s", "std_step_time_s", "min_step_time_s", "max_step_time_s")
    with (target / "strong-scaling-all-runs.csv").open("w", newline="") as stream:
        writer = csv.DictWriter(stream, fieldnames=fields)
        writer.writeheader()
        for result in results:
            values = result.values
            writer.writerow({
                "cores": result.run.cores, "nodes": result.run.nodes,
                "tasks_per_node": result.run.tasks_per_node,
                "source_launch": result.run.launch, "source_log": result.source_log,
                "actual_cells": result.run.actual_cells,
                "cells_per_core": f"{result.run.cells_per_core:.1f}",
                "total_records": result.total_records, "stat_steps": len(values),
                "mean_step_time_s": f"{result.mean:.6f}",
                "std_step_time_s": f"{result.stddev:.6f}",
                "min_step_time_s": f"{min(values):.6f}",
                "max_step_time_s": f"{max(values):.6f}",
            })

    grouped: dict[int, list[Result]] = defaultdict(list)
    for result in results:
        grouped[result.run.cores].append(result)
    points = []
    for cores, group in sorted(grouped.items()):
        means = [item.mean for item in group]
        representative = group[-1]
        points.append((cores, representative.run.nodes, representative.run.tasks_per_node, len(group), representative.run.actual_cells, representative.run.cells_per_core, len(representative.values), statistics.fmean(means), statistics.stdev(means) if len(means) > 1 else statistics.fmean(item.stddev for item in group)))
    baseline_cores, baseline_mean = points[0][0], points[0][7]

    with (target / "strong-scaling-summary.csv").open("w", newline="") as stream:
        writer = csv.writer(stream)
        writer.writerow(("cores", "nodes", "tasks_per_node", "runs", "actual_cells", "cells_per_core", "stat_steps", "mean_step_time_s", "std_step_time_s", "speedup", "efficiency_percent"))
        for point in points:
            speedup = baseline_mean / point[7]
            efficiency = 100.0 * speedup / (point[0] / baseline_cores)
            writer.writerow((*point[:7], f"{point[7]:.6f}", f"{point[8]:.6f}", f"{speedup:.6f}", f"{efficiency:.3f}"))

    title = f"OpenFOAM Strong-Scaling Summary — {label}; physical time ({args.start_time:g}, {args.end_time:g}]"
    lines = ["=" * 144, title, "=" * 144,
             f"{'Cores (Nodes)':<15}{'Nodes':>7}{'TPN':>7}{'Runs':>7}{'Total Cells':>14}{'Cells/Core':>14}{'Stat Steps':>12}{'Mean Step (s)':>16}{'Std Step (s)':>14}{'Speedup':>11}{'Efficiency':>12}",
             "-" * 144]
    for point in points:
        speedup = baseline_mean / point[7]
        efficiency = 100.0 * speedup / (point[0] / baseline_cores)
        lines.append(f"{f'{point[0]} ({point[1]})':<15}{point[1]:>7}{point[2]:>7}{point[3]:>7}{point[4]:>14}{point[5]:>14.1f}{point[6]:>12}{point[7]:>16.4f}{point[8]:>14.4f}{speedup:>10.2f}x{efficiency:>11.1f}%")
    lines.append("=" * 144)
    text = "\n".join(lines) + "\n"
    (target / "strong-scaling-summary.txt").write_text(text)
    print(text, end="")

    # Plot runtime, normalized speedup, and efficiency on separate axes so each
    # metric keeps its own scale and interpretation.
    import matplotlib.pyplot as plt
    cores = [point[0] for point in points]
    means = [point[7] for point in points]
    speedups = [baseline_mean / value for value in means]
    ideal_speedups = [core / baseline_cores for core in cores]
    efficiencies = [100.0 * speed / ideal for speed, ideal in zip(speedups, ideal_speedups)]

    fig, (time_axis, speedup_axis, efficiency_axis) = plt.subplots(
        3, 1, figsize=(9, 12), constrained_layout=True
    )

    # Mean timestep time is compared with the ideal inverse-core-count trend.
    time_axis.plot(cores, means, "o-", label="Measured mean step time")
    time_axis.plot(
        cores,
        [baseline_mean / ideal for ideal in ideal_speedups],
        "--",
        label="Ideal strong scaling",
    )
    time_axis.set_xscale("log", base=2)
    time_axis.set_yscale("log", base=2)
    time_axis.set(xlabel="Cores", ylabel="Mean step time (s)", title=title)
    time_axis.grid(True, which="both", alpha=0.3)
    time_axis.legend()

    # A base-2 log-log scale shows each doubling clearly; ideal speedup is the
    # straight line S(p) = p / p0 through the baseline value of 1.
    speedup_axis.plot(cores, speedups, "o-", label="Measured speedup")
    speedup_axis.plot(cores, ideal_speedups, "--", label="Ideal speedup")
    speedup_axis.set_xscale("log", base=2)
    speedup_axis.set_yscale("log", base=2)
    speedup_axis.set(xlabel="Cores", ylabel="Speedup")
    speedup_axis.grid(True, which="both", alpha=0.3)
    speedup_axis.legend()

    # Parallel efficiency remains a percentage and uses a 100% reference line.
    efficiency_axis.plot(cores, efficiencies, "o-", label="Parallel efficiency")
    efficiency_axis.axhline(100.0, linestyle="--", label="Ideal efficiency")
    efficiency_axis.set_xscale("log", base=2)
    efficiency_axis.set(xlabel="Cores", ylabel="Efficiency (%)")
    efficiency_axis.grid(True, which="both", alpha=0.3)
    efficiency_axis.legend()

    fig.savefig(target / "strong-scaling-plot.png", dpi=180)
    fig.savefig(target / "strong-scaling-plot.pdf")
    plt.close(fig)
    print(f"Analysis written to: {target}")


# ============================================================================
# 7. Program coordination
#
# Resolve the case-local artifact root, optionally rebuild accumulated links,
# analyse the requested source, and update accumulated results after a campaign.
# ============================================================================

def main() -> int:
    args = parse_args()
    try:
        if args.recipe_dir:
            case_root = args.recipe_dir.resolve() / "artifacts/tests/strong-scaling" / args.case_name
            if not case_root.is_dir():
                raise ValueError(f"case artifact root not found: {case_root}")
            if args.rebuild_accumulated:
                sources = rebuild_accumulated(case_root)
                for source in sources:
                    runtime, mesh = source.parts[-2:]
                    results = [analyse_run(run, args.start_time, args.end_time) for run in discover_runs(source, args.point_mode)]
                    write_outputs(results, source, f"Accumulated ({runtime}, {mesh})", args)
                return 0
            if args.runtime and args.cells_millions:
                source_dir = case_root / "accumulated" / args.runtime / f"{args.cells_millions}M"
            elif (case_root / "accumulated/latest").exists():
                source_dir = (case_root / "accumulated/latest").resolve()
            else:
                source_dir = (case_root / "latest").resolve()
        else:
            source_dir = args.artifacts_dir.resolve()
            case_root = source_dir
            while case_root.parent.name != "strong-scaling":
                if case_root == case_root.parent:
                    raise ValueError(f"cannot identify case artifact root from {source_dir}")
                case_root = case_root.parent
            if case_root.name != args.case_name:
                raise ValueError(f"artifact case '{case_root.name}' does not match --case '{args.case_name}'")

        results = [analyse_run(run, args.start_time, args.end_time) for run in discover_runs(source_dir, args.point_mode)]
        label = f"Accumulated ({source_dir.parent.name}, {source_dir.name})" if source_dir.parent.parent.name == "accumulated" else f"Single launch: {source_dir.name}"
        write_outputs(results, source_dir, label, args)

        if not args.single_launch_only and source_dir.parent == case_root:
            accumulated = link_campaign(case_root, source_dir)
            results = [analyse_run(run, args.start_time, args.end_time) for run in discover_runs(accumulated, args.point_mode)]
            write_outputs(results, accumulated, f"Accumulated ({accumulated.parent.name}, {accumulated.name})", args)
        return 0
    except (KeyError, OSError, ValueError) as error:
        print(f"ERROR: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
