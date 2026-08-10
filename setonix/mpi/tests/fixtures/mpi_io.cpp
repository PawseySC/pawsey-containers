#include <iostream>
#include <vector>
#include <random>
#include <algorithm>
#include <chrono>
#include <cmath>
#include <stdio.h>
#include <sys/stat.h>
#include <string>
#include <iomanip>
#include <sstream>
#include <cstdlib>
#include <cstdio>
#include <fstream>
#include <filesystem>

#include <mpi.h>

// Global variables relating to the MPI communicator and world
// Rank number, world, size, and root rank
int world_rank, world_size;
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

// Create file names with paths based on rank and file number
std::string get_filename(int file_num, const std::string& directory, std::string mode)
{
    std::string fname;
    fname = static_cast<std::ostringstream&>(std::ostringstream().seekp(0) << directory << "/file_" <<  file_num << "." << mode).str();
    return fname;
}

void WriteCollective(std::string &fname, size_t fsize, std::vector<double> buffer)
{
    Rank0LocalLoggerWithTime() << " Starting collective write to " << fname << std::endl;

    MPI_File file;
    MPI_Offset offset;
    MPI_Status status;
    // Calculate the offset based on the rank
    offset = ThisTask * buffer.size() * sizeof(double);

    // Record timing of writes
    double start_time, end_time;
    start_time = MPI_Wtime();

    // Open file for writing
    MPI_File_delete(fname.c_str(), MPI_INFO_NULL);
    MPI_File_open(MPI_COMM_WORLD, fname.c_str(), MPI_MODE_CREATE | MPI_MODE_WRONLY, MPI_INFO_NULL, &file);
    // Write to the file using collective I/O - all processes conrtibute to the file write
    MPI_File_write_at_all(file, offset, buffer.data(), buffer.size(), MPI_DOUBLE, &status);

    // Close the file
    MPI_File_close(&file);
    end_time = MPI_Wtime();

    // Report timing
    double local_time = end_time - start_time;
    double max_time;
    MPI_Reduce(&local_time, &max_time, 1,MPI_DOUBLE, MPI_MAX, 0,MPI_COMM_WORLD);
    auto bandwidth = (fsize / max_time) / (1024.0 * 1024.0 * 1024.0);
    Rank0LocalLoggerWithTime()
        << " Completed collective write to "
        << fname << " in " << max_time << " seconds, "
        << "with effective bandwidth" << bandwidth << " GB/s" << std::endl;
}

void WriteNonCollective(std::string &fname, size_t fsize, std::vector<double> buffer)
{
    Rank0LocalLoggerWithTime() << " Starting non-collective write to " << fname << std::endl;

    MPI_File file;
    MPI_Offset offset;
    MPI_Status status;
    // Calculate the offset based on the rank
    offset = ThisTask * buffer.size() * sizeof(double);

    // Record timing of writes
    double start_time, end_time;
    start_time = MPI_Wtime();

    // Open file for writing
    MPI_File_delete(fname.c_str(), MPI_INFO_NULL);
    MPI_File_open(MPI_COMM_WORLD, fname.c_str(), MPI_MODE_CREATE | MPI_MODE_WRONLY, MPI_INFO_NULL, &file);
    // Write to the file using non-collective I/O - each process writes independently at its own offset
    MPI_File_write_at(file, offset, buffer.data(), buffer.size(), MPI_DOUBLE, &status);

    // Close the file
    MPI_File_close(&file);
    end_time = MPI_Wtime();

    // Report timing
    double local_time = end_time - start_time;
    double max_time;
    MPI_Reduce(&local_time, &max_time, 1,MPI_DOUBLE, MPI_MAX, 0,MPI_COMM_WORLD);
    auto bandwidth = (fsize / max_time) / (1024.0 * 1024.0 * 1024.0);
    Rank0LocalLoggerWithTime()
        << " Completed non-collective write to "
        << fname << " in " << max_time << " seconds, "
        << "with effective bandwidth" << bandwidth << " GB/s" << std::endl;
}

void ReadCollective(std::string &fname, size_t fsize, std::vector<double> buffer)
{
    Rank0LocalLoggerWithTime() << " Starting collective read from " << fname << std::endl;

    MPI_File file;
    MPI_Offset offset;
    MPI_Status status;
    // Calculate the offset based on the rank
    offset = ThisTask * buffer.size() * sizeof(double);

    // Record timing of writes
    double start_time, end_time;
    start_time = MPI_Wtime();

    // Open file for reading
    MPI_File_open(MPI_COMM_WORLD, fname.c_str(), MPI_MODE_RDONLY, MPI_INFO_NULL, &file);
    // Read from the file using collective I/O - all processes conrtibute to the file write
    MPI_File_read_at_all(file, offset, buffer.data(), buffer.size(), MPI_DOUBLE, &status);

    // Close the file
    MPI_File_close(&file);
    end_time = MPI_Wtime();

    // Report timing
    double local_time = end_time - start_time;
    double max_time;
    MPI_Reduce(&local_time, &max_time, 1,MPI_DOUBLE, MPI_MAX, 0,MPI_COMM_WORLD);
    auto bandwidth = (fsize / max_time) / (1024.0 * 1024.0 * 1024.0);
    Rank0LocalLoggerWithTime()
        << " Completed collective read from "
        << fname << " in " << max_time << " seconds, "
        << "with effective bandwidth" << bandwidth << " GB/s" << std::endl;
}

void ReadNonCollective(std::string &fname, size_t fsize, std::vector<double> buffer)
{
    Rank0LocalLoggerWithTime() << " Starting non-collective read from " << fname << std::endl;

    MPI_File file;
    MPI_Offset offset;
    MPI_Status status;
    // Calculate the offset based on the rank
    offset = ThisTask * buffer.size() * sizeof(double);

    // Record timing of writes
    double start_time, end_time;
    start_time = MPI_Wtime();

    // Open file for reading
    MPI_File_open(MPI_COMM_WORLD, fname.c_str(), MPI_MODE_RDONLY, MPI_INFO_NULL, &file);
    // Read from the file using non-collective I/O - each process writes independently at its own offset
    MPI_File_read_at(file, offset, buffer.data(), buffer.size(), MPI_DOUBLE, &status);

    // Close the file
    MPI_File_close(&file);
    end_time = MPI_Wtime();

    // Report timing
    double local_time = end_time - start_time;
    double max_time;
    MPI_Reduce(&local_time, &max_time, 1,MPI_DOUBLE, MPI_MAX, 0,MPI_COMM_WORLD);
    auto bandwidth = (fsize / max_time) / (1024.0 * 1024.0 * 1024.0);
    Rank0LocalLoggerWithTime()
        << " Completed non-collective read from "
        << fname << " in " << max_time << " seconds, "
        << "with effective bandwidth" << bandwidth << " GB/s" << std::endl;
}

int main(int argc, char* argv[])
{
    // Initial MPI setup
    MPI_Init(&argc, &argv);
    MPI_Comm_size(MPI_COMM_WORLD, &NProcs);
    MPI_Comm_rank(MPI_COMM_WORLD, &ThisTask);

    // Ensure proper number of arguments are provided
    if (argc != 4) {
        if (ThisTask == 0)
        {
            std::cerr << "Usage: " << argv[0] << " <num_files> <file_size_in_bytes> <directory>\n";
        }
        MPI_Abort(MPI_COMM_WORLD, 1);
    }

    int nfiles = atoi(argv[1]);
    size_t file_size = atol(argv[2]);
    std::string directory = argv[3];

    // Ensure directory exists
    if (!std::filesystem::exists(directory) || !std::filesystem::is_directory(directory))
    {
        if (ThisTask == 0)
        {
            std::cerr << "The specified directory does not exist or is not a valid directory: " << directory << std::endl;
        }
        MPI_Abort(MPI_COMM_WORLD, 1);
    }


    // Ensure the number of files and file size are positive
    if (nfiles <= 0 || file_size <= 0) {
        if (ThisTask == 0)
        {
            std::cerr << "Error: num_files and file_size must be positive integers.\n";
        }
        MPI_Abort(MPI_COMM_WORLD, 1);
    }

    // Each process will write a portion of the total file size (in bytes).
    if (file_size % sizeof(double) != 0)
    {
        if (ThisTask == 0)
        {
            std::cerr << "Warning: File size is not a multiple of the size of a double, truncating last element.\n";
        }
    }

    int nentries_per_rank = file_size / (NProcs * sizeof(double));
    std::vector<double> write_buffer(nentries_per_rank, ThisTask + 1.0);
    std::vector<double> read_buffer(nentries_per_rank, -1.0);

    // Write nfiles files, using both collective and non-collective writes
    // Then read from those same files, using both collective and non-collective read operations
    for (int fid = 0; fid < nfiles; ++fid)
    {
        std::string non_collective_fname = get_filename(fid, directory, "non-collective");
        std::string collective_fname = get_filename(fid, directory, "collective");

        // Non-collective write
        WriteNonCollective(non_collective_fname, file_size, write_buffer);
        // Synchronise ranks before moving on
        MPI_Barrier(MPI_COMM_WORLD);
        // Collective write
        WriteCollective(collective_fname, file_size, write_buffer);
        // Synchronise ranks before moving on
        MPI_Barrier(MPI_COMM_WORLD);

        // Non-collective read
        ReadCollective(non_collective_fname, file_size, read_buffer);
        // Synchronise ranks before moving on
        MPI_Barrier(MPI_COMM_WORLD);
        // Reset read buffer
        fill(read_buffer.begin(), read_buffer.end(), -1.0);
        // Synchronise ranks before moving on
        MPI_Barrier(MPI_COMM_WORLD);
        // Collective read
        ReadNonCollective(collective_fname, file_size, read_buffer);
    }

    if (ThisTask == 0) {
        char version[MPI_MAX_LIBRARY_VERSION_STRING];
        int len = 0;
        MPI_Get_library_version(version, &len);
        printf("\n=== MPI runtime ===\n%.*s\n", len, version);
        printf("\nTEST_05_MPI_CONTAINER_IO_SUCCESS size=%d\n", NProcs);
    }
    MPI_Finalize();
    return 0;
}