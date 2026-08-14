/*!
  \file test_mpi.cpp
  \brief Test MPI communication performance and memory footprint.
  \details This test performs various MPI communication patterns (e.g., broadcast, send/recv).  Note that this is a
    deliberately trimmed down version of the original for simple functionality and rough performance testing
  \author Pascal Elahi (original), Craig Meyer (trimmed)

*/

#include <iostream>
#include <vector>
#include <chrono>
#include <cmath>
#include <algorithm>
#include <random>
#include <tuple>
#include <thread>
#include <mpi.h>
#include <getopt.h>

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
    /// what types of communication to test
    bool igather = true;
    bool ireduce = true;
    bool iscatter = true;
    bool ibcast = true;
    bool isendrecv = true;
    bool isendrecvsinglerank = true;
    /// root task that will get all the receives
    int roottask = 0;
    int othertask = 0;
    /// max message size in GB
    double msg_size = 1.0;
    int Niter = 1;

};

/// usage
void usage()
{
    Rank0LocalLogger()<<"Options: "<<std::endl;
    Rank0LocalLogger()<<"  -s <max message size in GB> (default 1.0) "<<std::endl;
    Rank0LocalLogger()<<"  -i <number of iterations for each test> (default 1) "<<std::endl;
    Rank0LocalLogger()<<"  -m <message size in number of doubles for long delay test> (default 1000) "<<std::endl;
    Rank0LocalLogger()<<"  -R <1 to test reduce> "<<std::endl;
    Rank0LocalLogger()<<"  -B <1 to test bcast> "<<std::endl;
    Rank0LocalLogger()<<"  -P <1 to test sendrecv> "<<std::endl;
    Rank0LocalLogger()<<"  -p <1 to test sendrecv with single rank> "<<std::endl;
    MPI_Finalize();
    exit(0);
}

///routine to get arguments from command line
void GetArgs(int argc, char *argv[], Options &opt)
{
    opt.othertask = NProcs/2 + 1;
    int option;
    while ((option = getopt(argc, argv, ":s:i:m:G:R:S:B:P:p:")) != EOF)
    {
        switch(option)
        {
            case 's':
                opt.msg_size = atof(optarg);
                break;
            case 'i':
                opt.Niter = atoi(optarg);
                break;
            case 'R':
                opt.ireduce = atoi(optarg);
                break;
            case 'B':
                opt.ibcast = atoi(optarg);
                break;
            case 'P':
                opt.isendrecv = atoi(optarg);
                break;
            case 'p':
                opt.isendrecvsinglerank = atoi(optarg);
                break;
            case '?':
                usage();
                break;
        }
    }
}


/// \defgroup Performance
//@{
void MPITestBcast(Options &opt)
{
    MPI_Status status;
    std::string mpifunc = "Bcast";
    LogMPITest()
    std::vector<double> data;
    double nbytes = opt.msg_size * 1024.0 * 1024.0 * 1024.0;
    double nelements = nbytes / sizeof(double);
    double * p1 = nullptr, *p2 = nullptr;

    // Initialise data
    data.resize(nelements);
    for (auto &d:data) d = pow(2.0,ThisTask);
    p1 = data.data();
    
    // Each rank broadcasts <nelements> doubles to <NProcs - 1> ranks <Niter> times
    std::vector<double> local_times;
    for (auto itask=0;itask<NProcs;itask++)
    {
        for (auto iter=0;iter<opt.Niter;iter++) {
            double start_time = MPI_Wtime();
            MPI_Bcast(p1, nelements, MPI_DOUBLE, itask, MPI_COMM_WORLD);
            double end_time = MPI_Wtime();
            double local_time = end_time - start_time;
            local_times.push_back(local_time);
        }
    }
    
    // Record the maximum average time across all ranks
    double avg_time = 0.0, total_time = 0.0;
    for (auto &t:times) total_time += t;
    avg_time = total_time / local_times.size();
    double max_avg_time;
    MPI_Allreduce(&avg_time, &max_avg_time, 1, MPI_DOUBLE, MPI_MAX, MPI_COMM_WORLD);

    // Record the effective bandwidth. Each broadcast sends <Nprocs - 1> * <opt.msg_size> GB of data
    double gbytes_per_bcast = (NProcs - 1) * opt.msg_size;
    double bw = gbytes_per_bcast / max_avg_time;

    // Report basic stats
    Rank0LocalLoggerWithTime()
        << "Test " << mpifunc << " finished with avg communication time of " << max_avg_time << " seconds"
        << ", with effective bandwidth " << bw << " GB/s " 
        << "and message size of " << opt.msg_size << " GB." << std::endl;
    
    // Cleanup
    times.clear();
    p1 = p2 = nullptr;
    data.clear();
    data.shrink_to_fit();
}

void MPITestSendRecvSingleRank(Options &opt)
{
    std::cout << "In sendrecvseinglerank" << std::endl;
    MPI_Status status;
    std::string mpifunc = "sendrecv_singlerank";
    LogMPITest();
    std::vector<double> senddata, receivedata;
    double nbytes = opt.msg_size * 1024.0 * 1024.0 * 1024.0;
    double nelements = nbytes / sizeof(double);
    double * p1 = nullptr, *p2 = nullptr;

    // Initialise data
    senddata.resize(nelements);
    receivedata.resize(nelements);
    for (auto &d:senddata) d = pow(2.0,ThisTask);
    p1 = senddata.data();
    p2 = receivedata.data();

    MPI_Status stat;
    std::vector<std::string> messages;
    std::vector<double> local_times;
    // The root rank sends <nelements> doubles to one rank and receives <nelements> doubles from one rank <Niter> times
    for (auto itask=0;itask<NProcs;itask++)
    {
        if (itask == opt.roottask) continue;
        for (auto iter=0;iter<opt.Niter;iter++)
        {
            if (ThisTask == opt.roottask)
            {
                double start_time = MPI_Wtime();
                MPI_Sendrecv(p1, nelements, MPI_DOUBLE, itask, itask, p2, nelements, MPI_DOUBLE, itask, itask, MPI_COMM_WORLD, &stat);
                double end_time = MPI_Wtime();
                double local_time = end_time - start_time;
                times.push_back(local_time);
                messages.push_back(std::to_string(itask) + ": " + std::to_string(local_time));
            }
            else if (itask == ThisTask) {
                MPI_Sendrecv(p1, nelements, MPI_DOUBLE, opt.roottask, itask, p2, nelements, MPI_DOUBLE, opt.roottask, itask, MPI_COMM_WORLD, &stat);
            }
        }
    }

    // Record the average time across all sendrecv operations
    double avg_time = 0.0, total_time = 0.0;
    for (auto &t:times) total_time += t;
    double avg_time = total_time / times.size();

    // Record the effective bandwidth. Each sendrecv moves 2 * <opt.msg_size> GB of data
    double gbytes_per_sendrecv = 2 * opt.msg_size;
    double bw = gbytes_per_sendrecv / avg_time;

    // Report basic stats
    Rank0LocalLoggerWithTime()
        << "Test " << mpifunc << " finished with avg communication time of " << avg_time << " seconds"
        << ", with effective bandwidth " << bw << " GB/s " 
        << "and message size of " << opt.msg_size << " GB." << std::endl;

    // Cleanup
    times.clear();
    senddata.clear();
    senddata.shrink_to_fit();
    receivedata.clear();
    receivedata.shrink_to_fit();
}

void MPITestSendRecv(Options &opt)
{
    MPI_Status status;
    std::string mpifunc = "sendrecv";
    LogMPITest();
    std::vector<double> senddata, receivedata;
    double nbytes = opt.msg_size * 1024.0 * 1024.0 * 1024.0;
    double nelements = nbytes / sizeof(double);
    double * p1 = nullptr, *p2 = nullptr;

    // Initialise data
    senddata.resize(nelements);
    receivedata.resize(nelements);
    for (auto &d:senddata) d = pow(2.0,ThisTask);
    p1 = senddata.data();
    p2 = receivedata.data();

    std::vector<double> times;
    // Each rank sends <nelements> doubles to all other ranks <NIter> times
    for (auto iter=0;iter<opt.Niter;iter++) {
        double start_time = MPI_Wtime();
        std::vector<MPI_Request> sendreqs, recvreqs;
        for (auto isend=0;isend<NProcs;isend++)
        {
            if (isend != ThisTask)
            {
                MPI_Request request;
                int tag = isend*NProcs+ThisTask;
                MPI_Isend(p1, nelements, MPI_DOUBLE, isend, tag, MPI_COMM_WORLD, &request);
                sendreqs.push_back(request);
            }
        }
        for (auto irecv=0;irecv<NProcs;irecv++)
        {
            if (irecv != ThisTask)
            {
                MPI_Request request;
                int tag = ThisTask*NProcs+irecv;
                MPI_Irecv(p2, nelements, MPI_DOUBLE, irecv, tag, MPI_COMM_WORLD, &request);
                recvreqs.push_back(request);
            }
        }
        if (!recvreqs.empty()) {
            MPI_Waitall(static_cast<int>(recvreqs.size()), recvreqs.data(), MPI_STATUSES_IGNORE);
        }
        if (!sendreqs.empty()) {
            MPI_Waitall(static_cast<int>(sendreqs.size()), sendreqs.data(), MPI_STATUSES_IGNORE);
        }
        double end_time = MPI_Wtime();
        double local_time = end_time - start_time;
        times.push_back(local_time);
    }

    // Record the maximum average time across all ranks
    double avg_time = 0.0, total_time = 0.0;
    for (auto &t:times) total_time += t;
    avg_time = total_time / times.size();
    double max_avg_time;
    MPI_Allreduce(&avg_time, &max_avg_time, 1, MPI_DOUBLE, MPI_MAX, MPI_COMM_WORLD);

    // Record the effective bandwidth. Each sendrecv moves <Nprocs - 1> * 2 * <opt.msg_size> GB of data
    double gbytes_per_sendrecv = (NProcs - 1) * (2 * opt.msize);
    double bw = gbytes_per_sendrecv / max_avg_time;
    
    // Report basic stats
    Rank0LocalLoggerWithTime()
        << "Test " << mpifunc << " finished with avg communication time of " << max_avg_time << " seconds"
        << ", with effective bandwidth " << bw << " GB/s " 
        << "and message size of " << opt.msg_size << " GB." << std::endl;
    
    // Cleanup
    times.clear();
    senddata.clear();
    senddata.shrink_to_fit();
    receivedata.clear();
    receivedata.shrink_to_fit();
}

void MPITestAllReduce(Options &opt)
{
    MPI_Status status;
    std::string mpifunc = "allreduce";
    LogMPITest();
    std::vector<double> data, allreducesum;
    double nbytes = opt.msg_size * 1024.0 * 1024.0 * 1024.0;
    double nelements = nbytes / sizeof(double);
    double * p1 = nullptr, *p2 = nullptr;

    // Initialise data
    data.resize(nelements);
    allreducesum.resize(nelements);
    for (auto &d:data) d = pow(2.0,ThisTask);
    p1 = data.data();
    p2 = allreducesum.data();

    std::vector<double> times;
    MPI_Barrier(MPI_COMM_WORLD);
    for (auto iter=0;iter<opt.Niter;iter++) {
        double start_time = MPI_Wtime();
        MPI_Allreduce(p1, p2, nelements, MPI_DOUBLE, MPI_SUM, MPI_COMM_WORLD);
        double end_time = MPI_Wtime();
        double local_time = end_time - start_time;
        times.push_back(local_time);
    }
    
    // Record the maximum average time across all ranks
    double avg_time = 0.0, total_time = 0.0;
    for (auto &t:times) total_time += t;
    avg_time = total_time / times.size();
    double max_avg_time;
    MPI_Allreduce(&avg_time, &max_avg_time, 1, MPI_DOUBLE, MPI_MAX, MPI_COMM_WORLD);

    // Report basic stats
    Rank0LocalLoggerWithTime()
        << "Test " << mpifunc << " finished with avg communication time of " << max_avg_time << " seconds"
        << "and message size of " << opt.msg_size << " GB." << std::endl;
    
    // Cleanup
    times.clear();
    data.clear();
    data.shrink_to_fit();
    allreducesum.clear();
    allreducesum.shrink_to_fit();
}
//@}

void MPIRunTests(Options &opt)
{
    if (opt.isendrecvsinglerank) MPITestSendRecvSingleRank(opt);
    if (opt.ireduce) MPITestAllReduce(opt);
    if (opt.ibcast) MPITestBcast(opt);
    if (opt.isendrecv) MPITestSendRecv(opt);
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
    MPIRunTests(opt);

    Rank0LocalLogger()<<"Ending job "<<std::endl;
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