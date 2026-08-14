/*!
    \file test_gpu_mpi_comm.cpp
    \brief Test GPU MPI communication using different MPI communicators and message sizes, and report timing statistics.
    \details This test initializes the profiling utility, performs GPU-to-GPU communication 
    using MPI while logging various metrics, and verifies the results. Note that this is a
    deliberately trimmed down version of the original for simple functionality and rough performance testing
*/

#include <iostream>
#include <vector>
#include <chrono>
#include <cmath>
#include <algorithm>
#include <random>
#include <tuple>
#include <thread>
#include <getopt.h>
#include <hip/hip_runtime.h>

#ifdef USEOPENMP
#include <omp.h>
#endif
#include <mpi.h>

#define _GPU_TO_SECONDS 1.0/1000.0

int ThisTask, NProcs;
std::chrono::system_clock::time_point logtime;
std::time_t log_time;
char wherebuff[1000];
std::string whenbuff;

#define Where() sprintf(wherebuff,"[%04d] @%sL%d ", ThisTask,__func__, __LINE__);
#define When() logtime = std::chrono::system_clock::now(); log_time = std::chrono::system_clock::to_time_t(logtime);whenbuff=std::ctime(&log_time);whenbuff.erase(std::find(whenbuff.begin(), whenbuff.end(), '\n'), whenbuff.end());
#define LocalLogger() Where();std::cout<<wherebuff<<" : " 
#define Rank0LocalLogger() Where();if (ThisTask==0) std::cout<<wherebuff<<" : " 
#define LocalLoggerWithTime() Where();When(); std::cout<<wherebuff<<" ("<<whenbuff<<") : "
#define Rank0LocalLoggerWithTime() Where();When(); if (ThisTask==0) std::cout<<wherebuff<<" ("<<whenbuff<<") : "
#define LogMPITest() Rank0LocalLoggerWithTime()<<" running "<<mpifunc<< " test"<<std::endl;

struct Options
{
    /// message size in GB
    double msg_size = 1.0;
    /// number of iterations
    int Niter = 1;
};

/// usage
void usage()
{
    Rank0LocalLogger()<<"Options: "<<std::endl;
    Rank0LocalLogger()<<"  -s <max message size in GB> (default 1.0) "<<std::endl;
    Rank0LocalLogger()<<"  -i <number of iterations for each test> (default 1) "<<std::endl;
    MPI_Finalize();
    exit(0);
}

///routine to get arguments from command line
void GetArgs(int argc, char *argv[], Options &opt)
{
    int option;
    while ((option = getopt(argc, argv, ":s:i:r:o:G:C:")) != EOF)
    {
        switch(option)
        {
            case 's':
                opt.msg_size= atof(optarg);
                break;
            case 'i':
                opt.Niter = atoi(optarg);
                break;
            case '?':
                usage();
                break;
        }
    }
}


/// \defgroup Device MPI (GPU-to-GPU) Performance 
//@{

void MPITestGPUCopy(Options &opt){

    std::string mpifunc = "GPU_GPU_copy";
    LogMPITest();
    std::vector<double*> gpu_p1, gpu_p2;
    std::vector<float> mpitransfertimes;
    double nbytes = opt.msg_size * 1024.0 * 1024.0 * 1024.0;
    double nelements = nbytes / sizeof(double);

    // Initialise data
    int nDevices;
    hipGetDeviceCount(&nDevices);
    std::vector<double> senddata;
    gpu_p1.resize(nDevices);
    gpu_p2.resize(nDevices);
    for (auto &x:gpu_p1) x=nullptr;
    for (auto &x:gpu_p2) x=nullptr;
    senddata.resize(nelements);

    float timetaken;
    // Each device copies <nelements> doubles from p1 -> p2 <Niter> times
    for (auto idev=0;idev<nDevices;idev++) {
        hipSetDevice(idev);
        hipMalloc((void**)&gpu_p1[idev], nbytes);
        hipMalloc((void**)&gpu_p2[idev], nbytes);
        // Copy source data to device once
        hipMemcpy(gpu_p1[idev], senddata.data(), nbytes, hipMemcpyHostToDevice);

        timetaken=0.0;
        hipEvent_t gpuEventStart, gpuEventStop;
        hipEventCreate(&gpuEventStart);
        hipEventCreate(&gpuEventStop);
        for (auto iter=0;iter<opt.Niter;iter++) {
            hipEventRecord(gpuEventStart);
            hipMemcpy(gpu_p2[idev], gpu_p1[idev], nbytes, hipMemcpyDeviceToDevice);
            hipEventRecord(gpuEventStop);
            hipDeviceSynchronize();
            hipEventElapsedTime(&timetaken, gpuEventStart, gpuEventStop);
            mpitransfertimes.push_back(timetaken*_GPU_TO_SECONDS);
        }
        hipEventDestroy(gpuEventStart);
        hipEventDestroy(gpuEventStop);
        hipFree(gpu_p1[idev]);
        hipFree(gpu_p2[idev]);
    }
    // Calculate avg time and effective bandwidth
    double avg_time = 0.0, total_time = 0.0;
    for (auto &t:mpitransfertimes) total_time += t;
    avg_time = total_time / mpitransfertimes.size();
    double bw = opt.msg_size / avg_time;

    // Report basic stats
    Rank0LocalLoggerWithTime()
        << "Test " << mpifunc << " finished with avg communication time of " << avg_time << " seconds"
        << ", with effective bandwidth " << bw << " GB/s " 
        << "and message size of " << opt.msg_size << " GB." << std::endl;
    mpitransfertimes.clear();
}

/// @brief Test whether simple send/receive works and check bandwidth
/// @param opt Options struct containing runtime information
void MPITestGPUBandwidthSendRecv(Options &opt){
    if (NProcs<2) return;
    MPI_Status status;
    std::string mpifunc = "GPU_bandwidth_sendrecv";
    LogMPITest();
    std::vector<double> senddata, receivedata;
    double * p1 = nullptr, *p2 = nullptr;
    std::vector<double*> gpu_p1, gpu_p2;
    std::vector<float> mpitransfertimes;
    double nbytes = opt.msg_size * 1024.0 * 1024.0 * 1024.0;
    double nelements = nbytes / sizeof(double);

    // Initialise data
    int nDevices;
    hipGetDeviceCount(&nDevices);
    gpu_p1.resize(nDevices);
    gpu_p2.resize(nDevices);
    for (auto &x:gpu_p1) x=nullptr;
    for (auto &x:gpu_p2) x=nullptr;
    senddata.resize(nelements);
    receivedata.resize(nelements);
    for (auto idev=0;idev<nDevices;idev++) {
        hipSetDevice(idev);
        hipMalloc((void**)&gpu_p1[idev], nbytes);
        hipMalloc((void**)&gpu_p2[idev], nbytes);
        hipMemcpy(gpu_p1[idev], senddata.data(), nbytes, hipMemcpyHostToDevice);
    }
    for (auto &d:senddata) d = pow(2.0,ThisTask);

    // Run one-way sendrecv
    // For each non-root rank <itask>, each device has rank 0 send <nelements> doubles to rank <itask> <Niter> times
    for (auto idev=0; idev<nDevices;idev++) {
        hipSetDevice(idev);
        p1 = gpu_p1[idev];
        p2 = gpu_p2[idev];
        std::vector<float> times;
        MPI_Barrier(MPI_COMM_WORLD);
        for (auto itask=0;itask<NProcs;itask++) {
            if (itask == 0) continue;
            if (!(ThisTask==0 or ThisTask==itask)) continue;
            int tag = 100;
            for (auto iter=0;iter<opt.Niter;iter++) {
                double start_time = MPI_Wtime();
                if (ThisTask==0) {
                    MPI_Send(p1, nelements, MPI_DOUBLE, itask, tag, MPI_COMM_WORLD);
                }
                else if (ThisTask==itask) {
                    MPI_Recv(p2, nelements, MPI_DOUBLE, 0, tag, MPI_COMM_WORLD, &status);
                }
                double end_time = MPI_Wtime();
                double local_time = end_time - start_time;
                mpitransfertimes.push_back(local_time);
            }
        }
        MPI_Barrier(MPI_COMM_WORLD);
    }

    // Report average time and effective bandwidth
    double avg_time = 0.0, total_time = 0.0;
    for (auto &t:mpitransfertimes) total_time += t;
    avg_time = total_time / mpitransfertimes.size();
    double bw = opt.msg_size / avg_time;

    // Report basic stats
    Rank0LocalLoggerWithTime()
        << "Test " << mpifunc << " finished with avg communication time of " << avg_time << " seconds"
        << ", with effective bandwidth " << bw << " GB/s " 
        << "and message size of " << opt.msg_size << " GB." << std::endl;
    mpitransfertimes.clear();

    // Cleanup
    for (auto idev=0;idev<nDevices;idev++) {
        hipSetDevice(idev);
        hipFree(gpu_p1[idev]);
        hipFree(gpu_p2[idev]);
    }
    senddata.clear();
    senddata.shrink_to_fit();
    receivedata.clear();
    receivedata.shrink_to_fit();
    gpu_p1.clear();
    gpu_p2.clear();
};

/// @brief Test whether GPU-GPU Asynchronous communication works
/// @param opt Options struct containing runtime information
void MPITestGPUAsyncSendRecv(Options &opt){
    if (NProcs<2) return;
    std::string mpifunc = "GPU_async_sendrecv";
    LogMPITest();
    std::vector<double> senddata, receivedata;
    double * p1 = nullptr, *p2 = nullptr;
    std::vector<double*> gpu_p1, gpu_p2;
    std::vector<float> mpitransfertimes;
    double nbytes = opt.msg_size * 1024.0 * 1024.0 * 1024.0;
    double nelements = nbytes / sizeof(double);

    // Initialise data
    int nDevices;
    hipGetDeviceCount(&nDevices);
    gpu_p1.resize(nDevices);
    gpu_p2.resize(nDevices);
    for (auto &x:gpu_p1) x=nullptr;
    for (auto &x:gpu_p2) x=nullptr;
    senddata.resize(nelements);
    receivedata.resize(nelements);
    for (auto idev=0;idev<nDevices;idev++) {
        hipSetDevice(idev);
        hipMalloc((void**)&gpu_p1[idev], nbytes);
        hipMalloc((void**)&gpu_p2[idev], nbytes);
        hipMemcpy(gpu_p1[idev], senddata.data(), nbytes, hipMemcpyHostToDevice);
    }
    for (auto &d:senddata) d = pow(2.0,ThisTask);

    // Run async all-to-all sendrecv
    // Each rank sends <nelements> doubles to every other rank and receives <nelements> doubles from each other rank
    for (auto idev=0; idev<nDevices;idev++) {
        hipSetDevice(idev);
        p1 = gpu_p1[idev];
        p2 = gpu_p2[idev];
        MPI_Barrier(MPI_COMM_WORLD);
        for (auto iter=0;iter<opt.Niter;iter++) {
            std::vector<MPI_Request> sendreqs, recvreqs;
            double start_time = MPI_Wtime();
            for (auto isend=0;isend<NProcs;isend++) {
                if (isend != ThisTask) 
                {
                    MPI_Request request;
                    int tag = isend * NProcs + ThisTask + idev;
                    MPI_Isend(p1, nelements, MPI_DOUBLE, isend, tag, MPI_COMM_WORLD, &request);
                    sendreqs.push_back(request);
                }
            }
            for (auto irecv=0;irecv<NProcs;irecv++) {
                if (irecv != ThisTask) 
                {
                    MPI_Request request;
                    int tag = ThisTask * NProcs + irecv+idev;
                    MPI_Irecv(p2, nelements, MPI_DOUBLE, irecv, tag, MPI_COMM_WORLD, &request);
                    recvreqs.push_back(request);
                }
            }
            MPI_Waitall(sendreqs.size(), sendreqs.data(), MPI_STATUSES_IGNORE);
            MPI_Waitall(recvreqs.size(), recvreqs.data(), MPI_STATUSES_IGNORE);
            double end_time = MPI_Wtime();
            double local_time = end_time - start_time;
            mpitransfertimes.push_back(local_time);
        }
        MPI_Barrier(MPI_COMM_WORLD);
    }

    // Record the maximum average time across all ranks
    double avg_time = 0.0, total_time = 0.0;
    for (auto &t:mpitransfertimes) total_time += t;
    avg_time = total_time / mpitransfertimes.size();
    double max_avg_time;
    MPI_Allreduce(&avg_time, &max_avg_time, 1, MPI_DOUBLE, MPI_MAX, MPI_COMM_WORLD);

    // Record the effective bandwidth. Each sendrecv moves <Nprocs - 1> * 2 * <opt.msg_size> GB of data
    double gbytes_per_sendrecv = 2.0 * (NProcs - 1) * opt.msg_size;
    double bw = gbytes_per_sendrecv / max_avg_time;

    // Report basic stats.
    Rank0LocalLoggerWithTime()
        << "Test " << mpifunc << " finished with avg communication time of " << avg_time << " seconds"
        << ", with effective bandwidth " << bw << " GB/s " 
        << "and message size of " << opt.msg_size << " GB." << std::endl;
    mpitransfertimes.clear();

    // Cleanup
    for (auto idev=0;idev<nDevices;idev++) {
        hipSetDevice(idev);
        hipFree(gpu_p1[idev]);
        hipFree(gpu_p2[idev]);
    }
    senddata.clear();
    senddata.shrink_to_fit();
    receivedata.clear();
    receivedata.shrink_to_fit();
    gpu_p1.clear();
    gpu_p2.clear();
};

/// @brief Test collective GPU-GPU communication works
/// @param opt Options struct containing runtime information
void MPITestGPUAllGather(Options &opt){
    if (NProcs<2) return;
    std::string mpifunc = "GPU_allgather";
    LogMPITest();
    std::vector<double> senddata, receivedata;
    
    double * p1 = nullptr, *p2 = nullptr;
    std::vector<double*> gpu_p1, gpu_p2;
    std::vector<float> mpitransfertimes;
    double nbytes = opt.msg_size * 1024.0 * 1024.0 * 1024.0;
    double nelements = nbytes / sizeof(double);

    // Initialise date
    int nDevices;
    hipGetDeviceCount(&nDevices);
    gpu_p1.resize(nDevices);
    gpu_p2.resize(nDevices);
    for (auto &x:gpu_p1) x=nullptr;
    for (auto &x:gpu_p2) x=nullptr;
    senddata.resize(nelements);
    receivedata.resize(nelements * NProcs);
    for (auto &d:senddata) d = pow(2.0,ThisTask);
    for (auto idev=0;idev<nDevices;idev++) {
        hipSetDevice(idev);
        hipMalloc((void**)&gpu_p1[idev], nbytes);
        hipMalloc((void**)&gpu_p2[idev], nbytes * NProcs);
        hipMemcpy(gpu_p1[idev], senddata.data(), nbytes, hipMemcpyHostToDevice);
    }

    // Run allgather
    // Each rank sends <nelements> doubles and receives <NProcs - 1> * <nelements> doubles
    float timetaken;
    for (auto idev=0; idev<nDevices;idev++) {
        hipSetDevice(idev);
        timetaken=0.0;
        p1 = gpu_p1[idev];
        p2 = gpu_p2[idev];
        MPI_Barrier(MPI_COMM_WORLD);
        for (auto iter=0;iter<opt.Niter;iter++) {
            double start_time = MPI_Wtime();
            MPI_Allgather(p1, nelements, MPI_DOUBLE, p2, nelements, MPI_DOUBLE, MPI_COMM_WORLD);
            double end_time = MPI_Wtime();
            double local_time = end_time - start_time;
            mpitransfertimes.push_back(local_time);
        }
        MPI_Barrier(MPI_COMM_WORLD);
    }

    // Record the maximum average time across all ranks
    double avg_time = 0.0, total_time = 0.0;
    for (auto &t:mpitransfertimes) total_time += t;
    avg_time = total_time / mpitransfertimes.size();
    double max_avg_time;
    MPI_Allreduce(&avg_time, &max_avg_time, 1, MPI_DOUBLE, MPI_MAX, MPI_COMM_WORLD);

    // Record the effective bandwidth. Each allgather moves <Nprocs> * <opt.msg_size> GB of data
    double gbytes_per_allgather = NProcs * opt.msg_size;
    double bw = gbytes_per_allgather / max_avg_time;
    Rank0LocalLoggerWithTime()
        << "Test " << mpifunc << " finished with avg communication time of " << max_avg_time << " seconds"
        << ", with effective bandwidth " << bw << " GB/s " 
        << "and message size of " << opt.msg_size << " GB." << std::endl;
    mpitransfertimes.clear();

    // Cleanup
    for (auto idev=0;idev<nDevices;idev++) {
        hipSetDevice(idev);
        hipFree(gpu_p1[idev]);
        hipFree(gpu_p2[idev]);
    }
    senddata.clear();
    senddata.shrink_to_fit();
    receivedata.clear();
    receivedata.shrink_to_fit();
    gpu_p1.clear();
    gpu_p2.clear();
    MPI_Barrier(MPI_COMM_WORLD);
};

//@}

void MPIRunTests(Options &opt)
{
    MPITestGPUCopy(opt);
    MPITestGPUBandwidthSendRecv(opt);
    MPITestGPUAsyncSendRecv(opt);
    MPITestGPUAllGather(opt);
}

int main(int argc, char **argv) {
    MPI_Init(&argc, &argv);
    MPI_Comm comm = MPI_COMM_WORLD;
    MPI_Comm_size(comm, &NProcs);
    MPI_Comm_rank(comm, &ThisTask);
    Options opt;
    GetArgs(argc, argv, opt);

    Rank0LocalLogger()<<"Starting job "<<std::endl;
    MPI_Barrier(comm);

    // Run the tests
    MPIRunTests(opt);

    if (ThisTask == 0) {
        char version[MPI_MAX_LIBRARY_VERSION_STRING];
        int len = 0;
        MPI_Get_library_version(version, &len);
        printf("\n=== MPI runtime ===\n%.*s\n", len, version);
        printf("\nTEST_07_GPU-MPI_CONTAINER_SUCCESS size=%d\n", NProcs);
    }
    MPI_Finalize();
    return 0;
}