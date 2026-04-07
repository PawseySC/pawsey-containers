#!/bin/bash
script_dir="$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )"

# Get today's date in yyyy/mm format
DATE_TAG=$(date +%Y/%m)

# Replace slashes with dashes for Docker tag compatibility
DATE_TAG=$(echo $DATE_TAG | tr '/' '-')

# Execute download.sh
echo "Executing download.sh..."
bash $script_dir/download.sh

# Check if download.sh executed successfully
if [ $? -ne 0 ]; then
  echo "download.sh execution failed. Exiting."
  exit 1
fi

# Based nvidia/cuda:12.5.0-devel-ubuntu22.04
BASE_NAME="nvidia/cuda:12.5.0-devel-ubuntu22.04"
# Build Docker image with the date tag
echo "Building Docker image on ${BASE_NAME} with tag ${DATE_TAG}..."
docker build -t cuda-lustre-mpich:${DATE_TAG} -f buildcudalustrempich.dockerfile --build-arg DATE_TAG=${DATE_TAG} .

# Check if Docker build was successful
if [ $? -ne 0 ]; then
  echo "Docker build failed. Exiting."
  exit 1
fi

echo "Docker image built successfully with tag ${DATE_TAG}."
