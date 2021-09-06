# original list for intelpython (except h5py and mpi4py)
#
# astropy
# cython
# dask
# matplotlib
# nose
# numba
# pandas
# pytest
# scikit-learn

# dry-runs to have a look at versions
#conda install --no-update-deps -d  astropy cython dask matplotlib nose numba pandas pytest scikit-learn
# ideally newer dask and pandas
#conda install --no-update-deps -d  astropy cython dask==2.24.0 matplotlib nose numba pandas==1.1.1 pytest scikit-learn
# newer pandas conflicts ..
#conda install --no-update-deps -d  astropy cython dask==2.24.0 matplotlib nose numba pandas pytest scikit-learn

# as of 19 March 2021, the plain list of packages (no versions) now works

### PREPARE LIST OF VERSIONED PACKAGES
# let's install
#conda install --no-update-deps -y  astropy cython dask==2.24.0 matplotlib nose numba pandas pytest scikit-learn
conda install --no-update-deps -y  --file requirements.in
# let's freeze
REQ_LABEL="19Mar2021"
ENV_FILE="environment-${REQ_LABEL}.yaml"
conda env export >${ENV_FILE}
# let's convert from environment to requirements
REQ_FILE="requirements-${REQ_LABEL}.yaml"
cp $ENV_FILE $REQ_FILE
sed -i -n '/dependencies/,/prefix/p' $REQ_FILE 
sed -i -e '/dependencies:/d' -e '/prefix:/d' $REQ_FILE 
sed -i 's/ *- //g' $REQ_FILE 


### OK NOW FOR REAL - in the Dockerfile
#conda install --no-update-deps -y  --file ${REQ_FILE}
# HDF5 parallel install
# 
# pip for h5py and mpi4py
#


## Performance note for scikit-learn
## INSTALLED PACKAGE OF SCIKIT-LEARN CAN BE ACCELERATED USING DAAL4PY. \n\n  PLEASE SET 'USE_DAAL4PY_SKLEARN' ENVIRONMENT VARIABLE TO 'YES' TO ENABLE THE ACCELERATION. \n\n  FOR EXAMPLE:\n\n      $ USE_DAAL4PY_SKLEARN=YES python



