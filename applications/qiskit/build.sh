#!/bin/bash

script_dir="$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )"
AER_VERSION="0.14.2"

# Function to convert input to lowercase
to_lowercase() {
  echo "$1" | tr '[:upper:]' '[:lower:]'
}

# Prompt user for input
echo "Build qiskit-aer backend for different hardware accelerators."
read -p "Please enter a backend (CUDA/ROCM/OMP/MPI/cuQuantum) accelerators: " user_input

# Convert input to lowercase
input_lower=$(to_lowercase "$user_input")

# Valid options
valid_options=("cuda" "rocm" "omp" "mpi" "cuquantum")

# Check if input is valid
is_valid=false
for option in "${valid_options[@]}"; do
  if [ "$input_lower" == "$option" ]; then
    is_valid=true
    break
  fi
done

# Handle invalid input
if [ "$is_valid" = false ]; then
  echo "Invalid input. Please enter one of the following: CUDA, ROCM, OMP, MPI, cuQuantum."
  exit 1
fi

# Store the valid input for later use
backend=$input_lower

# Output the chosen backend
echo "You have selected the backend: $backend"

# Download qiskit-aer source and checkout the specified version
echo "We are going to download the qiskit-aer and checkout the version: $AER_VERSION"
mkdir -p $script_dir/qiskit-aer-build
cd $script_dir/qiskit-aer-build
git clone https://github.com/Qiskit/qiskit-aer $script_dir/qiskit-aer-build
cd $script_dir/qiskit-aer-build
git checkout $AER_VERSION

# download the required dependencies, lustre, mpich, osu-benchmarks
# DEBUG: Comment the following line to download the dependencies
bash "$script_dir/download.sh"

# 1)OMP
# 2)MPI-3.4.3
# 3)CUDA-12.5
# 4)ROCM 
# 5)cuQuantum
# 6)CUDAQ-CUDA 11.8

cd $script_dir
if [ "$backend" == "mpi" ]; then
  #docker buildx build --file ${script_dir}/buildqiskit-mpi.dockerfile --platform linux/amd64 -t qiskit-mpi:latest --load .
  docker build --pull --rm -f "buildqiskit-mpi.dockerfile" -t qiskit-mpi:latest . 
fi

if [ "$backend" == "rocm" ]; then
  docker build --pull --rm -f "buildqiskit-rocm.dockerfile" -t qiskit-rocm-mpi:latest . 
fi

if [ "$backend" == "cuda" ]; then
  docker buildx build --file buildqiskit-cuda.dockerfile --platform linux/amd64,linux/arm64 -t qiskit-cuda12-mpi:latest  .
fi

# DEBUG: Comment the following line to del the downloaded files
rm -rf $script_dir/qiskit-aer-build