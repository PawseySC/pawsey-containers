#!/bin/bash

#------------------------
#Properly delete the existing working directories
find -P ./CFD -type f -print0 -o -type l -print0 | xargs -0 munlink
find -P ./DEM -type f -print0 -o -type l -print0 | xargs -0 munlink
find ./CFD -depth -type d -empty -delete
find ./DEM -depth -type d -empty -delete

#------------------------
echo "Working directories have been removed. Done"
