#!/bin/bash
# This script was used to identify the "meaning" of the different settings in the ENTRYPOINT
# directive in the Dockerfile when starting a Docker container.
# For easier testing, we recommend to use a pointer towards this file from the "entry file" (now a link) from the image
# instead of COPYing this file into the entry file of the image and build it (although that would work too).
# When using a link, the host directory containing the real script should be binded to the correct directory set inside the image.
# The script indicates the results of what would happen with different ENTRYPOINT settings in the 4th argument (read below).
# So there is no need to build separate images for different settings, as this script tell what would happen.
# Although if you do not want to see what would happen but really observe it happenning, then there is no other option but
# building an image per different ENTRYPOINT setting.
#
# This script tests the effect of the 4th argument in a setting like this:
#       ENTRYPOINT["/bin/bash", "-l, "-c", "\"$@\"", "--"]
# (note that each member of the list of arguments shuold be in between double quotes).
# Here the 4th argument is in practice:
#       "$@"
# (note that `\` in the directive allowed to preserve the quotes inside the compulsory quotes).
# The setting in this example is interpreted as the effective Entrypoint command:
#       '/bin/bash' '-l' '-c' '"$@"' '--' $CMD
# where the ultimate command $CMD could be the <defaultCommand> set in the Dockerfile:
#       CMD["<defaultCommand>"]
# or the <givenCommand> in the command line:
#       $ docker run --rm <imageName> <givenCommand>
# The interpretation of the effective Entrypoint command is formed by three main blocks:
# BLOCK 1. The basic command:
#       '/bin/bash' '-l' '-c'  (which in effect becomes "bash -l -c")
# BLOCK 2. The command provided to that "bash -l -c" which is indeed the interpretation of the 4th argument:
#        interpretation of '"$@"' = $CMD
#    So the 4th argument interpreter, the command provided with the arguments that follow
#    except for the argument-zero (first next following argument), which is discarded.
#    So, in the more concrete example of:
#       $ docker run --rm theImage ls -latd .
#    The effective entrypoint command becomes:
#       '/bin/bash' '-l' '-c' '"$@"' '--' 'ls' '-latd' '.'
#    which, after interpretation of the 4th argument, the above command becomes:
#       '/bin/bash' '-l' '-c' 'ls' '-latd' '.' '--' 'ls' '-latd' '.'
#    So the 4th argument interpreter built a command provided (BLOCK 2) as:
#       'ls' '-latd' '.'
#    Note that the reason for using `--` as the 5th argument in the ENTRYPOINT is to allow the 4th argument interpreter
#    to pick up the full command. Otherwise, the interpreter would have discarded 'ls' as argument-zero and
#    pick up only '-ltad' '.' causing a mess.
# BLOCK 3. 5th argument (to be discarded) and the rest of the line (This BLOCK 3 forms "the feeding" to 4th argument interpreter):
#       '--' $CMD
#    or in terms of the concrete example:
#       '--' 'ls' '-latd' '.'
#
# IMPORTANT: Note that BLOCK 2 is kept as the argument list to be inherited to any script that is sourced from the entrypoint script.
#            This is important for OpenFOAM images, as the prepared workflow indeed sources the bashrc script on entry to the container.
#            Therefore, for OpenFOAM images, it is important to:
#                       - save the list of arguments in an auxiliary list before sourcing the bashrc script
#                       - clean the argument list before sourcing the bashrc script
#                       - source the bashrc script
#                       - recover the argument list from the auxiliary list
#
# As mentioned, this script tests the effect of the 4th argument settings.
# All the possibilities tested here are:
# Entry 1 ("$@"):       ENTRYPOINT["/bin/bash", "-l, "-c", "\"$@\"", "--"]
# Entry 2 ($@)  :       ENTRYPOINT["/bin/bash", "-l, "-c", "$@", "--"]
# Entry 3 ("$*"):       ENTRYPOINT["/bin/bash", "-l, "-c", "\"$*\"", "--"]
# Entry 4 ($*)  :       ENTRYPOINT["/bin/bash", "-l, "-c", "$*", "--"]
#(The last one being the setting in use in past Dockerfiles)
#
# These are expected results when using this script as the `/env/profile.d/entryScript.sh` in an image
# with the correspoinding ENTRYPOINT settings in a concrete command example:
#       $ docker run --rm theImage ls -latd .
# The interpretation of 4th argument are:
# Entry 1 ("$@"): 'ls' '-latd' '.'
# Entry 2 ($@)  : 'ls' '-latd' '.'
# Entry 3 ("$*"): 'ls' '-latd' '.'
# Entry 4 ($*)  : 'ls -latd .'
# (Note the difference for the fourth test, which fails as the whole string is tried to be recognised as a single command.)
#
# The emulation of behaviour from the host command line without running any container:
# Entry 1 ("$@"): bash -l -c 'source <thisScript.sh>;"$@"' -- ls -latd .
# Entry 2 ($@)  : bash -l -c 'source <thisScript.sh>;$@' -- ls -latd .
# Entry 3 ("$*"): bash -l -c 'source <thisScript.sh>;"$*"' -- ls -latd .
# Entry 4 ($*)  : bash -l -c 'source <thisScript.sh>;$@' -- ls -latd .
#
# And the correct final execution (only tests 1-3) of the ultimate command:
#      ls -latd .
# should finally print:
#      drwxr-sr-x 4 mickey pawsey1234 4096 Apr 14 12:14 . 

# These are expected results when using this script as the `/env/profile.d/entryScript.sh` in an image
# with the correspoinding ENTRYPOINT settings in a concrete command example:
#       $ docker run --rm theImage bash -c 'echo "MYVAR_CHECK=$MYVAR_CHECK"'
# (Note that MYVAR_CHECK is set down in this same script, so this command should
#       printout the defined value.)
# The interpretation of 4th argument are:
# Entry 1 ("$@"): 'bash' '-c' 'echo "MYVAR_CHECK=$MYVAR_CHECK"'
# Entry 2 ($@)  : 'bash' '-c' 'echo' '"MYVAR_CHECK=$MYVAR_CHECK"'
# Entry 3 ("$*"): 'bash -c echo "MYVAR_CHECK=$MYVAR_CHECK"'
# Entry 4 ($*)  : 'bash' '-c' 'echo' '"MYVAR_CHECK=$MYVAR_CHECK"'
# (Note that only the test 1 gives the correct behaviour for the ultimate command.)
#
# The emulation of behaviour from the host command line without running any container:
# Entry 1 ("$@"): bash -l -c 'source <thisScript.sh>;"$@"' -- bash -c 'echo "MYVAR_CHECK=$MYVAR_CHECK"'
# Entry 2 ($@)  : bash -l -c 'source <thisScript.sh>;$@' -- bash -c 'echo "MYVAR_CHECK=$MYVAR_CHECK"'
# Entry 3 ("$*"): bash -l -c 'source <thisScript.sh>;"$*"' -- bash -c 'echo "MYVAR_CHECK=$MYVAR_CHECK"'
# Entry 4 ($*)  : bash -l -c 'source <thisScript.sh>;$@' -- bash -c 'echo "MYVAR_CHECK=$MYVAR_CHECK"'
#
# And the correct final execution (only test 1) of the ultimate command:
#       bash -c 'echo "MYVAR_CHECK=$MYVAR_CHECK"'
# should finally print:
#       MYVAR_CHECK=CCCC

# --- Start
echo "============================"
# --- Show the explicit positional variables
echo "=== Explicit positional variables"
echo "The \"argument-zero\" which is discarded by the Docker ENTRYPOINT setting being tested:"
echo "0: $0"
echo "Number of arguments: $#"
for ((i=1; i<=$#; i++)); do
   echo "$i: ${!i}"
done

# --- Loop over arguments
echo
echo "=== Test 1: 4th argument as (including quotes): \"\$@\""
commy=""
i=0
for arg in "$@"; do
   ((i++))
   echo "Piece $i: '$arg'"
   commy+=" '$arg'"
done
commy="${commy# }"
echo "Interpretation: ${commy[@]}"

echo
echo "=== Test 2: 4th argument as (no quotes): \$@"
commy=""
i=0
for arg in $@; do
   ((i++))
   echo "Piece $i: '$arg'"
   commy+=" '$arg'"
done
commy="${commy# }"
echo "Interpretation: ${commy[@]}"

echo
echo "=== Test 3: 4th argument as (including quotes): \"\$*\""
commy=""
i=0
for arg in "$*"; do
   ((i++))
   echo "Piece $i: '$arg'"
   commy+=" '$arg'"
done
commy="${commy# }"
echo "Interpretation: ${commy[@]}"

echo
echo "=== Test 4: 4th argument as (no quotes): \$*"
commy=""
i=0
for arg in $*; do
   ((i++))
   echo "Piece $i: '$arg'"
   commy+=" '$arg'"
done
commy="${commy# }"
echo "Interpretation: ${commy[@]}"


# --- Defining some environment variable
export MYVAR_CHECK="CCCC"

# --- End
echo
echo "This is the end of the starting script!"
echo "What comes after the line is the result of the container execution:"
echo "============================"