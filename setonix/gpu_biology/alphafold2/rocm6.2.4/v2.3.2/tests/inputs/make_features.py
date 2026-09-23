"""Build an AlphaFold2 features.pkl from precomputed a3m MSAs (no database searches).

The GPU tests use this so they don't depend on the reference databases: the MSA
comes from the a3m files given here and a single empty placeholder template is
used (the same approach ColabFold takes). The result is what run_msa.py would
write, and is read by run_predict.py via --msa_path.

Monomer:
  python3 make_features.py --out features.pkl --a3m chainA.a3m
Multimer (one --a3m/--paired-a3m pair per chain, in chain order):
  python3 make_features.py --out features.pkl --multimer \
      --a3m chainA.a3m --paired-a3m chainA_paired.a3m \
      --a3m chainB.a3m --paired-a3m chainB_paired.a3m
"""
import argparse
import os
import pickle
import tempfile

import numpy as np
from alphafold.common import residue_constants
from alphafold.data import msa_pairing
from alphafold.data import parsers
from alphafold.data import pipeline
from alphafold.data import pipeline_multimer


def placeholder_template(sequence):
  """One all-zero template: masked out, so it contributes nothing."""
  num_res = len(sequence)
  aatype = residue_constants.sequence_to_onehot(
      'A' * num_res, residue_constants.HHBLITS_AA_TO_ID)
  return {
      'template_aatype': np.array(aatype, dtype=np.float32)[None],
      'template_all_atom_masks': np.zeros(
          (1, num_res, residue_constants.atom_type_num), dtype=np.float32),
      'template_all_atom_positions': np.zeros(
          (1, num_res, residue_constants.atom_type_num, 3), dtype=np.float32),
      'template_domain_names': np.array([b'none'], dtype=np.object_),
      'template_sequence': np.array([b'none'], dtype=np.object_),
      'template_sum_probs': np.zeros((1, 1), dtype=np.float32),
  }


def read_a3m(path):
  with open(path) as f:
    msa = parsers.parse_a3m(f.read())
  return msa


def monomer_features(a3m_path, description):
  msa = read_a3m(a3m_path)
  sequence = msa.sequences[0]
  return {
      **pipeline.make_sequence_features(
          sequence=sequence, description=description, num_res=len(sequence)),
      **pipeline.make_msa_features([msa]),
      **placeholder_template(sequence),
  }


class PrecomputedMultimerPipeline(pipeline_multimer.DataPipeline):
  """AlphaFold's multimer pipeline with the per-chain MSA search replaced."""

  def __init__(self, chain_msas):
    # Deliberately skips the parent __init__, which sets up database searches.
    self._chain_msas = chain_msas  # sequence -> (a3m path, paired a3m path)

  def _process_single_chain(self, chain_id, sequence, description,
                            msa_output_dir, is_homomer_or_monomer):
    a3m_path, paired_a3m_path = self._chain_msas[sequence]
    features = monomer_features(a3m_path, description)
    if not is_homomer_or_monomer:
      all_seq = pipeline.make_msa_features([read_a3m(paired_a3m_path)])
      valid = msa_pairing.MSA_FEATURES + ('msa_species_identifiers',)
      features.update(
          {f'{k}_all_seq': v for k, v in all_seq.items() if k in valid})
    return features


def main():
  parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
  parser.add_argument('--out', required=True)
  parser.add_argument('--a3m', action='append', required=True)
  parser.add_argument('--paired-a3m', action='append', default=[])
  parser.add_argument('--multimer', action='store_true')
  args = parser.parse_args()

  if not args.multimer:
    features = monomer_features(args.a3m[0], 'query')
  else:
    if len(args.paired_a3m) != len(args.a3m):
      parser.error('give one --paired-a3m per --a3m')
    chain_msas, fasta = {}, ''
    for i, (a3m, paired) in enumerate(zip(args.a3m, args.paired_a3m)):
      sequence = read_a3m(a3m).sequences[0]
      chain_msas[sequence] = (a3m, paired)
      fasta += f'>chain_{i}\n{sequence}\n'
    with tempfile.TemporaryDirectory() as tmp:
      fasta_path = os.path.join(tmp, 'input.fasta')
      with open(fasta_path, 'w') as f:
        f.write(fasta)
      features = PrecomputedMultimerPipeline(chain_msas).process(
          input_fasta_path=fasta_path, msa_output_dir=tmp)

  with open(args.out, 'wb') as f:
    pickle.dump(features, f, protocol=4)
  print(f'wrote {args.out}: msa {features["msa"].shape}, '
        f'{len(features["aatype"])} residues')


if __name__ == '__main__':
  main()
