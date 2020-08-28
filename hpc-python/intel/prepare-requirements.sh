#!/bin/bash
# requires pip install pip-tools

REQ_LABEL="27Aug2020"
REQ_FILE="requirements-${REQ_LABEL}.txt"

pip-compile requirements.in -o ${REQ_FILE}
sed -i 's/^numpy/#numpy/g' ${REQ_FILE}

