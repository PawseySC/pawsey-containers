/*
 * mpi_perf_compare.c
 * MPI performance smoke test: prints rank-to-host mapping and MPI runtime details,
 * then measures rank 0/1 ping-pong latency/bandwidth for selected message sizes.
 * Also times repeated MPI_Allreduce calls and prints a success marker on completion.
 */

 /* 
 * Note:
 * This script has been developed by Alexis Espinosa with the help of Microsoft 360 Copilot - GPT 5.5.
 * This script has been fully reviewed by Alexis Espinosa at Pawsey Supercomputing Centre.
 */

#include <mpi.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

static void pingpong(int rank, int size, int msg_size, int iters)
{
    if (size < 2) return;

    char *buf = malloc((size_t)msg_size + 1);
    if (!buf) {
        fprintf(stderr, "malloc failed\n");
        MPI_Abort(MPI_COMM_WORLD, 10);
    }
    memset(buf, 1, (size_t)msg_size + 1);

    MPI_Barrier(MPI_COMM_WORLD);
    double t0 = MPI_Wtime();

    if (rank == 0) {
        for (int i = 0; i < iters; i++) {
            MPI_Send(buf, msg_size, MPI_CHAR, 1, 10, MPI_COMM_WORLD);
            MPI_Recv(buf, msg_size, MPI_CHAR, 1, 10, MPI_COMM_WORLD, MPI_STATUS_IGNORE);
        }
    } else if (rank == 1) {
        for (int i = 0; i < iters; i++) {
            MPI_Recv(buf, msg_size, MPI_CHAR, 0, 10, MPI_COMM_WORLD, MPI_STATUS_IGNORE);
            MPI_Send(buf, msg_size, MPI_CHAR, 0, 10, MPI_COMM_WORLD);
        }
    }

    double t1 = MPI_Wtime();

    if (rank == 0) {
        double roundtrip_us = (t1 - t0) * 1.0e6 / iters;
        double one_way_us = roundtrip_us / 2.0;
        double bandwidth_MBps = 0.0;

        if (msg_size > 0) {
            bandwidth_MBps = ((double)msg_size * 2.0 * iters) / (t1 - t0) / 1.0e6;
        }

        printf("PINGPONG msg_size=%d bytes iters=%d one_way_latency_us=%.3f roundtrip_us=%.3f bandwidth_MBps=%.3f\n",
               msg_size, iters, one_way_us, roundtrip_us, bandwidth_MBps);
    }

    free(buf);
}

static void allreduce_test(int rank, int iters)
{
    double x = (double)rank;
    double y = 0.0;

    MPI_Barrier(MPI_COMM_WORLD);
    double t0 = MPI_Wtime();

    for (int i = 0; i < iters; i++) {
        MPI_Allreduce(&x, &y, 1, MPI_DOUBLE, MPI_SUM, MPI_COMM_WORLD);
    }

    double t1 = MPI_Wtime();

    if (rank == 0) {
        double avg_us = (t1 - t0) * 1.0e6 / iters;
        printf("ALLREDUCE_DOUBLE iters=%d avg_latency_us=%.3f\n", iters, avg_us);
    }
}

int main(int argc, char **argv)
{
    MPI_Init(&argc, &argv);

    int rank, size;
    char host[256];

    MPI_Comm_rank(MPI_COMM_WORLD, &rank);
    MPI_Comm_size(MPI_COMM_WORLD, &size);
    gethostname(host, sizeof(host));

    if (rank == 0) {
        printf("MPI_PERF_TEST_BEGIN size=%d\n", size);

        char version[MPI_MAX_LIBRARY_VERSION_STRING];
        int len = 0;
        MPI_Get_library_version(version, &len);
        printf("MPI_RUNTIME_VERSION_BEGIN\n%.*s\nMPI_RUNTIME_VERSION_END\n", len, version);
    }

    printf("RANK_HOST rank=%d host=%s\n", rank, host);
    MPI_Barrier(MPI_COMM_WORLD);

    pingpong(rank, size, 0, 10000);
    pingpong(rank, size, 8, 10000);
    pingpong(rank, size, 1048576, 1000);

    allreduce_test(rank, 10000);

    if (rank == 0) {
        printf("MPI_PERF_TEST_SUCCESS size=%d\n", size);
    }

    MPI_Finalize();
    return 0;
}
