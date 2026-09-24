"""Write FreeBindCraft target and advanced settings for a short test run.

Starts from one of the image's own settings_advanced presets and only changes
what makes the run short: fewer design iterations, one trajectory, no
animations or plots, and fewer MPNN sequences.

  python make_settings.py PRESET MIN_LEN MAX_LEN PARAMS_DIR OUT_DIR
"""
import json
import os
import sys

APP = "/app/FreeBindCraft"

preset, min_len, max_len, params_dir, out_dir = sys.argv[1:6]
os.makedirs(out_dir, exist_ok=True)

target = {
    "design_path": os.path.join(os.path.abspath(out_dir), "design"),
    "binder_name": "PDL1",
    "starting_pdb": f"{APP}/example/PDL1.pdb",
    "chains": "A",
    "target_hotspot_residues": "56",
    "lengths": [int(min_len), int(max_len)],
    "number_of_final_designs": 1,
}

with open(f"{APP}/settings_advanced/{preset}.json") as f:
    advanced = json.load(f)
advanced.update({
    "soft_iterations": 20,
    "temporary_iterations": 10,
    "hard_iterations": 2,
    "greedy_iterations": 3,
    "max_trajectories": 1,
    "num_seqs": 4,
    "max_mpnn_sequences": 1,
    "save_design_animations": False,
    "save_design_trajectory_plots": False,
    "af_params_dir": params_dir,
})

with open(os.path.join(out_dir, "target.json"), "w") as f:
    json.dump(target, f, indent=2)
with open(os.path.join(out_dir, "advanced.json"), "w") as f:
    json.dump(advanced, f, indent=2)
print(f"wrote {out_dir}/target.json and {out_dir}/advanced.json from {preset}")
