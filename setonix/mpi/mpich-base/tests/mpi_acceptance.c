#include <mpi.h>
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>

int main(int argc, char **argv)
{
    MPI_Init(&argc, &argv);

    int rank, size;
    char host[256];

    MPI_Comm_rank(MPI_COMM_WORLD, &rank);
    MPI_Comm_size(MPI_COMM_WORLD, &size);
    gethostname(host, sizeof(host));

    int sum = 0;
    MPI_Allreduce(&rank, &sum, 1, MPI_INT, MPI_SUM, MPI_COMM_WORLD);

    int expected = size * (size - 1) / 2;
    if (sum != expected) {
        fprintf(stderr, "FAIL rank=%d allreduce=%d expected=%d\n", rank, sum, expected);
        MPI_Abort(MPI_COMM_WORLD, 1);
    }

    int dst = (rank + 1) % size;
    int src = (rank - 1 + size) % size;
    int send = rank;
    int recv = -1;

    MPI_Sendrecv(&send, 1, MPI_INT, dst, 99,
                 &recv, 1, MPI_INT, src, 99,
                 MPI_COMM_WORLD, MPI_STATUS_IGNORE);

    if (recv != src) {
        fprintf(stderr, "FAIL rank=%d recv=%d expected=%d\n", rank, recv, src);
        MPI_Abort(MPI_COMM_WORLD, 2);
    }

    printf("RANK_OK rank=%d size=%d host=%s\n", rank, size, host);

    if (rank == 0) {
        char version[MPI_MAX_LIBRARY_VERSION_STRING];
        int len = 0;
        MPI_Get_library_version(version, &len);
        printf("\n=== MPI runtime ===\n%.*s\n", len, version);
        printf("\nTEST_01_MPI_CONTAINER_BUILD_RUN_SUCCESS size=%d\n", size);
    }

    MPI_Finalize();
    return 0;
}
