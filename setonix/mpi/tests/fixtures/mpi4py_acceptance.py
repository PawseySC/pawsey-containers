#!/usr/bin/env python3

# Basic mpi4py acceptance test: verifies communicator collectives, ring sendrecv,
# broadcast, hostname gathering, and optional NumPy typed-buffer Allreduce.
# Rank 0 reports MPI/mpi4py runtime details, node distribution, and a success marker.

# Note:
# This script has been developed by Alexis Espinosa with the help of Microsoft 360 Copilot - GPT 5.5.
# This script has been fully reviewed by Alexis Espinosa at Pawsey Supercomputing Centre.

from mpi4py import MPI
import socket
import sys

try:
    import numpy as np
except Exception as exc:
    np = None
    numpy_error = repr(exc)
else:
    numpy_error = None

comm = MPI.COMM_WORLD
rank = comm.Get_rank()
size = comm.Get_size()
host = socket.gethostname()

# Basic communicator sanity
expected_sum = size * (size - 1) // 2
rank_sum = comm.allreduce(rank, op=MPI.SUM)
if rank_sum != expected_sum:
    raise RuntimeError(f"rank={rank}: allreduce sum={rank_sum}, expected={expected_sum}")

# Point-to-point sanity in a ring
send_value = rank
src = (rank - 1 + size) % size
dst = (rank + 1) % size
recv_value = comm.sendrecv(send_value, dest=dst, sendtag=101, source=src, recvtag=101)
if recv_value != src:
    raise RuntimeError(f"rank={rank}: sendrecv received {recv_value}, expected {src}")

# Broadcast sanity
root_value = {"message": "mpi4py-bcast-ok", "size": size} if rank == 0 else None
root_value = comm.bcast(root_value, root=0)
if root_value["message"] != "mpi4py-bcast-ok" or root_value["size"] != size:
    raise RuntimeError(f"rank={rank}: invalid bcast payload: {root_value}")

# Gather hostnames to verify node distribution
all_hosts = comm.allgather(host)
unique_hosts = sorted(set(all_hosts))

# Optional numpy buffer collective. This exercises mpi4py's typed-buffer path.
if np is not None:
    sendbuf = np.array([rank], dtype="i")
    recvbuf = np.array([-1], dtype="i")
    comm.Allreduce(sendbuf, recvbuf, op=MPI.SUM)
    if int(recvbuf[0]) != expected_sum:
        raise RuntimeError(
            f"rank={rank}: numpy-buffer Allreduce={int(recvbuf[0])}, expected {expected_sum}"
        )

print(f"RANK_OK rank={rank} size={size} host={host}", flush=True)

if rank == 0:
    print("\n=== mpi4py runtime information ===")
    print(f"mpi4py_version={MPI.Get_version()}")
    print(f"mpi_library_version_begin\n{MPI.Get_library_version()}mpi_library_version_end")
    print(f"unique_hosts={','.join(unique_hosts)}")
    print(f"unique_host_count={len(unique_hosts)}")
    if np is None:
        print(f"numpy_buffer_test=SKIPPED error={numpy_error}")
    else:
        print("numpy_buffer_test=PASSED")
    print(f"MPI4PY_ACCEPTANCE_SUCCESS size={size} unique_hosts={len(unique_hosts)}")
