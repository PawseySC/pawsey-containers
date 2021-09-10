#!/bin/bash

echo " ***** "
echo " This is a script to sync DockerHub OpenFOAM images onto Quay.io."
echo " Please ensure you are logged in to the container registry, otherwise push commands will fail."
echo " ***** "
echo ""


repo="pawsey/openfoam"
# Using chunks, to avoid filling up the hard-drive of small machines
of_tags_1="2.2.0 2.4.x 5.x 5.x_CFDEM"
of_tags_2="7 8 v1712 v1812"
of_tags_3="v1912 v2006 v2012"
chunks="of_tags_1 of_tags_2 of_tags_3"


# Using chunks, to avoid filling up the hard-drive of small machines
for of_tags in $chunks ; do
  for tag in ${!of_tags} ; do
    image="$repo:$tag"
    echo " .. Now syncing $image"
    docker pull $image
    docker tag $image quay.io/$image
    docker push quay.io/$image
    docker rmi quay.io/$image
  done

  for tag in ${!of_tags} ; do
    image="$repo:$tag"
    echo " .. Now syncing $image"
    docker rmi $image
  done
done


echo ""
echo " Gone through all syncs. Done!"
exit
