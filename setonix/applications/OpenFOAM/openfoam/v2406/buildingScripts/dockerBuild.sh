#!/usr/bin/env bash
# Script that builds the image using Docker
# NOTE: docker should be accessible already

# --- Initial settings
thisScript=$(basename "$0")
testNum=0
failedTests=()
totalFailed=0
stageName=""
recipeDir=".."
recipeFile="${recipeDir}/Dockerfile"

# --- Parse & validate command line arguments
stageName=""
stageFrom=""
while [[ $# -gt 0 ]]; do
   case $1 in
      --target)
         stageName="$2"
         if [[ -z "$stageName" ]]; then
            echo "ERROR: --target requires <stageName>" >&2
            echo "Usage: $0 [--target <stageName>] [--targetFrom <startingStage>]" >&2
            exit 1
         fi
         shift 2
         ;;
      --targetFrom)
         stageFrom="$2"
         if [[ -z "$stageFrom" ]]; then
            echo "ERROR: --targetFrom requires <startingStage>" >&2
            echo "Usage: $0 [--target <stageName>] [--targetFrom <startingStage>]" >&2
            exit 1
         fi
         shift 2
         ;;
      -h|--help)
         echo "Usage: $0 [--target <stageName>] [--targetFrom <startingStage>]"
         echo "  --target <stageName>     Build specific stage (requires FROM ... AS stageName)"
         echo "  --targetFrom <startingStage>  Start from specific stage (requires --target)"
         exit 0
         ;;
      *)
         echo "ERROR: Unknown option '$1'" >&2
         echo "Usage: $0 [--target <stageName>] [--targetFrom <startingStage>]" >&2
         exit 1
         ;;
   esac
done

# stageFrom validation
if [[ -n "$stageFrom" && -z "$stageName" ]]; then
   echo "ERROR: --targetFrom requires --target" >&2
   exit 1
fi

echo "Parsed: stageName='$stageName' stageFrom='$stageFrom'"
echo

# --- Step 1: Setting docker environment (STOP on fail)
#             Adapt process to your own system needs 
((++testNum))
echo "$thisScript: -----------------------------------------"
echo "Step $testNum - Starting Docker engine"
if ! docker info >/dev/null 2>&1; then
   echo "Starting Docker Desktop..."
   open -a Docker
   # Wait max 30s
   for i in {1..30}; do
      if docker info >/dev/null 2>&1; then
         break
      fi
      sleep 1
   done
fi
if ! docker info >/dev/null 2>&1; then
   echo "✖ Step $testNum FAIL: Docker failed to start"
   ((totalFailed++))
   exit 1
fi
echo "✓ Step $testNum PASS: Docker ready"
echo

# --- Step 2: Checking if docker is correctly set (STOP on fail)
#             Adapt checks to your own system needs
((++testNum))
echo "$thisScript: -----------------------------------------"
echo "Step $testNum - Checking if docker is accessible."
dockerVersion=$(docker --version)
if [[ -z "$dockerVersion" ]]; then
   echo "✖ Step $testNum FAIL: Failed to execute: docker --version"
   ((totalFailed++))
   exit 1
fi
echo "✓ Step $testNum dockerVersion=$dockerVersion"
echo "✓ Step $testNum PASS"
echo

# --- Step 3: Settings for defining image names (STOP on fail)
((++testNum))
echo "$thisScript: -----------------------------------------"
echo "Step $testNum - Setting the variables for defining names"
recipeDir=".."
recipeFile="${recipeDir}/Dockerfile"
OF_FORK=$(grep '^ARG OF_FORK=' "$recipeFile" 2>/dev/null | cut -d'"' -f2)
OF_VERSION=$(grep '^ARG OF_VERSION=' "$recipeFile" 2>/dev/null | cut -d'"' -f2)
OS_VERSION=$(grep '^ARG BASE_IMAGE_OS_VERSION=' "$recipeFile" 2>/dev/null | cut -d'"' -f2)

echo "OF_FORK: '$OF_FORK'"
echo "OF_VERSION: '$OF_VERSION'" 
echo "OS_VERSION: '$OS_VERSION'"

if [[ -z "$OF_FORK" || -z "$OF_VERSION" || -z "$OS_VERSION" ]]; then
   echo "✖ Step $testNum FAIL: Failed to extract required variables from Dockerfile"
   ((totalFailed++))
   exit 1
fi
echo "✓ Step $testNum PASS"
echo

# --- Step 4: Validate stage if provided (STOP on fail)
((++testNum))
echo "$thisScript: -----------------------------------------"
echo "Step $testNum - Validating if stage name exists in the Dockerfile"
if [[ -n "$stageName" ]]; then
   if ! grep -qiE "^FROM .* AS[[:space:]]+$stageName[[:space:]]*" "$recipeFile"; then
      echo "✖ Step $testNum FAIL: Stage '$stageName' not found in $recipeFile"
      echo "  Looking for line: FROM ... as $stageName"
      ((totalFailed++))
      exit 1
   fi
   echo "✓ Step $testNum PASS: Stage '$stageName' found"  
else
   echo "Step $testNum skipped. Not needed"  
fi
echo

# --- Step 5: Validate stageFrom if provided (STOP on fail)
((++testNum))
echo "$thisScript: -----------------------------------------"
echo "Step $testNum - Validating if stageFrom name exists in the Dockerfile"
if [[ -n "$stageFrom" ]]; then
   if ! grep -qiE "^FROM .* AS[[:space:]]+$stageFrom[[:space:]]*" "$recipeFile"; then
      echo "✖ Step $testNum FAIL: Stage '$stageFrom' not found in $recipeFile"
      echo "  Looking for line: FROM ... as $stageFrom"
      echo "  Can't be used as a stageFrom value"
      ((totalFailed++))
      exit 1
   fi
   echo "✓ Step $testNum PASS: Stage '$stageFrom' found"  
else
   echo "Step $testNum skipped. Not needed"  
fi
echo

# --- Step 6: Create temporary Dockerfile (if --targetFrom)
((++testNum))
tempRecipeFile=""
echo "$thisScript: -----------------------------------------"
echo "Step $testNum - Creating temp Dockerfile: FROM $stageFrom AS $stageName"
if [[ -n "$stageFrom" && -n "$stageName" ]]; then   
   tempRecipeFile="${recipeFile}.$$.tmp"
   cp "$recipeFile" "$tempRecipeFile"
   
   # Pass 1: Comment line starting with FROM, ending with AS $stageName
   sed "/^FROM .* AS[[:space:]]*$stageName$/s/^/#-ha-#/" "$tempRecipeFile" > "${tempRecipeFile}.new.tmp"

   # Pass 2: Insert new line after commented one
   sed "/^#-ha-#FROM .* AS[[:space:]]*$stageName$/a\\
FROM $stageFrom AS $stageName" "${tempRecipeFile}.new.tmp" > "$tempRecipeFile" && rm "${tempRecipeFile}.new.tmp"

   # Verify EXACT line exists
   if ! grep -q "^FROM[[:space:]]\+$stageFrom[[:space:]]\+AS[[:space:]]\+$stageName" "$tempRecipeFile"; then
      echo "✖ Step $testNum FAIL: No 'FROM $stageFrom AS $stageName' in $tempRecipeFile"
      ((totalFailed++))
      exit 1
   fi
   
   recipeFile="$tempRecipeFile"
   echo "✓ Step $testNum PASS: temporal $recipeFile created (1 line replaced)"
   echo "                      It will be used for the build with:"
   grep -iE "^FROM .* AS[[:space:]]+$stageName[[:space:]]*" $recipeFile
else
   echo "Step $testNum skipped no temporary Dockefile needed (no --targetFrom)"
fi
echo

# --- Step 7: Build the image (STOP on fail)
((++testNum))
imageName="${OF_FORK}"
imageTag="${OF_VERSION}-ubuntu${OS_VERSION}"
dockerOptions=""
if [[ -n "$stageName" ]]; then
   imageTag="${imageTag}-${stageName}"
   dockerOptions="--target $stageName"
fi
if [[ -n "$stageFrom" ]]; then
   imageTag="${imageTag}-from-${stageFrom}"
fi
imageFull="${imageName}:${imageTag}"
logFileBuild="log_build_docker.log"
#dockerOptions+=" --build-arg COMPILE_TASKS=24"
echo "$thisScript: -----------------------------------------"
echo "Step $testNum - Building with docker the image $imageFull"
# Timing the building command
echo "=== BUILD START: $(date)" | tee "$logFileBuild"
time docker build --progress=plain $dockerOptions -t "$imageFull" -f "$recipeFile" "$recipeDir" |& tee -a "$logFileBuild"
statusAll=(${PIPESTATUS[@]})
buildExit="${statusAll[0]}"
#echo "buildExit=$buildExit"
#echo "statusAll=${statusAll[*]}"
echo "=== BUILD END: $(date)" | tee -a "$logFileBuild"

if [[ $buildExit -ne 0 ]]; then
   echo "✖ Step $testNum FAIL: docker build failed (check $logFileBuild)"
   echo "buildExit=$buildExit"
   echo "statusAll=${statusAll[*]}"
   exit 1
fi
echo "✓ Step $testNum PASS: Build completed"
echo

# --- Step 8: Check existing image (STOP on fail)
((++testNum))
echo "$thisScript: -----------------------------------------"
echo "$thisScript: Step $testNum - Verifying image exists in docker registry"
if docker images -q "${imageFull}" | grep -q .; then
   imageRepo=$(docker image inspect "${imageFull}" --format '{{index .RepoTags 0}}')
   imageSize=$(docker images --format "{{.Size}}" "${imageFull}")
   echo "✓ Step $testNum PASS: Image found!"
   echo "  Repository: $imageRepo"
   echo "  Size: $imageSize"
else
   echo "✖ Step $testNum FAIL: Image '${imageFull}' not found in docker registry"
   docker images | grep "${imageFull}" || echo "  No matching images found"
   ((totalFailed++))
   exit 1
fi
echo

# --- Step 9: Checking logFileBuild for build success line (CONTINUE on fail)
((++testNum))
echo "$thisScript: -----------------------------------------"
echo "Step $testNum - Checking build success line"

if tail -10 "$logFileBuild" | grep -qE "naming to.*${imageFull}.*done"; then
   echo "✓ Step $testNum PASS: Success line found in $logFileBuild"
   tail -10 "$logFileBuild" | grep -E "naming to.*${imageFull}.*done"
else
   echo "✖ Step $testNum FAIL: No success line in $logFileBuild"
   echo "Last 10 lines:"
   tail -10 "$logFileBuild"
fi
echo

# --- Step 10: Check logFileBuild for Error messages (CONTINUE on fail)
((++testNum))
echo "$thisScript: -----------------------------------------"
echo "Step $testNum - Checking $logFileBuild for Error messages"
echo "Checking the file $logFileBuild"
if [[ -f $logFileBuild ]] ; then
   errorCount=$(grep -iE "\\bError\\b" "$logFileBuild" | grep -viEc 'Error[./-]|ignor')
   if [[ "$errorCount" -eq 0 ]]; then
      echo "✓ Step $testNum PASS: CLEAN of 'Error'(s) (not ignored) in $logFileBuild"
   else
      echo "✖ Step $testNum FAIL: $errorCount 'Error'(s) found in $logFileBuild"
      echo "First 5 errors:"
      grep -iE "\\bError\\b" "$logFileBuild" | grep -viE 'Error[./-]|ignor' | head -5
      failedTests+=("$testNum: $logFileBuild log has $errorCount errors")
      ((totalFailed++))
   fi
else
   echo "⚠ Step $testNum FAIL: $logFileBuild does not exist."
   failedTests+=("$testNum: $logFileBuild does not exist")
   ((totalFailed++))
fi
echo

# --- Step 11: Check ThirdParty compilation log (CONTINUE on fail)
((++testNum))
#logFile='$WM_THIRD_PARTY_DIR/log.Allwmake'
logFile='$WM_THIRD_PARTY_DIR/log.AllwmakeSummary'
echo "$thisScript: -----------------------------------------"
echo "Step $testNum - Checking that ThirdParty compilation finalised without 'Error'"
echo "Checking the file $logFile"
if docker run --rm "$imageFull" bash -c "[[ -f $logFile ]]" 2>/dev/null; then
   errorCount=$(docker run --rm "$imageFull" bash -c "grep -iE '\\bError\\b' \"$logFile\"" | grep -viEc 'Error[./-]|ignor')
   if [[ "$errorCount" -eq 0 ]]; then
      echo "✓ Step $testNum PASS: CLEAN of 'Error'(s) (not ignored) in $logFile"
   else
      echo "✖ Step $testNum FAIL: $errorCount 'Error'(s) found in $logFile"
      echo "First 5 errors:"
      docker run --rm "$imageFull" bash -c "grep -iE '\\bError\\b' \"$logFile\"" | grep -viE 'Error[./-]|ignor' | head -5
      failedTests+=("$testNum: ThirdParty log has $errorCount errors")
      ((totalFailed++))
   fi
else
   echo "⚠ Step $testNum FAIL: $logFile can't be read from the image $imageFull"
   echo "This may happen when building partial stages:"
   echo " -The file may not exist inside the image."
   echo " -Or it may exist but, if the last stage was not built, then it's not found because WM_THIRD_PARTY_DIR is not being set on entry."
   echo " In the latter case, then inspect the log file manually"
   failedTests+=("$testNum: ThirdParty log file not accessible")
   ((totalFailed++))
fi
echo

# --- Step 12: Check ParaView compilation log (CONTINUE on fail)
((++testNum))
logFile='$WM_THIRD_PARTY_DIR/log.makePV'
echo "$thisScript: -----------------------------------------"
echo "Step $testNum - Checking that ParaView compilation finalised without 'Error'"
echo "Checking the file $logFile"
if docker run --rm "$imageFull" bash -c "[[ -f $logFile ]]" 2>/dev/null; then
   errorCount=$(docker run --rm "$imageFull" bash -c "grep -iE '\\bError\\b' \"$logFile\"" | grep -viEc 'Error[./-]|ignor')
   if [[ "$errorCount" -eq 0 ]]; then
      echo "✓ Step $testNum PASS: CLEAN of 'Error'(s) (not ignored) in $logFile"
   else
      echo "✖ Step $testNum FAIL: $errorCount 'Error'(s) found in $logFile"
      echo "First 5 errors:"
      docker run --rm "$imageFull" bash -c "grep -iE '\\bError\\b' \"$logFile\"" | grep -viE 'Error[./-]|ignor' | head -5
      failedTests+=("$testNum: ParaView log has $errorCount errors")
      ((totalFailed++))
   fi
else
   echo "⚠ Step $testNum FAIL: $logFile can't be read from the image $imageFull"
   echo "This may happen when building partial stages:"
   echo " -The file may not exist inside the image."
   echo " -Or it may exist but, if the last stage was not built, then it's not found because WM_THIRD_PARTY_DIR is not being set on entry."
   echo " In the latter case, then inspect the log file manually"
   failedTests+=("$testNum: ParaView log file not accessible")
   ((totalFailed++))
fi
echo

# --- Step 13: Check OpenFOAM compilation log (CONTINUE on fail)
((++testNum))
logFile='$WM_PROJECT_DIR/log.AllwmakeSummary'
#logFile='$WM_PROJECT_DIR/log.Allwmake.1st_pass-parallel'
#logFile='$WM_PROJECT_DIR/log.Allwmake.2nd_pass-serial'
echo "$thisScript: -----------------------------------------"
echo "Step $testNum - Checking that OpenFOAM compilation finalised without 'Error'"
echo "Checking the file $logFile"
if docker run --rm "$imageFull" bash -c "[[ -f $logFile ]]" 2>/dev/null; then
   errorCount=$(docker run --rm "$imageFull" bash -c "grep -iE '\\bError\\b' \"$logFile\"" | grep -viE 'Error[./-]|ignor')
   if [[ "$errorCount" -eq 0 ]]; then
      echo "✓ Step $testNum PASS: CLEAN of 'Error'(s) (not ignored) in $logFile"
   else
      echo "✖ Step $testNum FAIL: $errorCount 'Error'(s) found in $logFile"
      echo "First 5 errors:"
      docker run --rm "$imageFull" bash -c "grep -iE '\\bError\\b' \"$logFile\"" | grep -viEc 'Error[./-]|ignor' | head -5
      failedTests+=("$testNum: OpenFOAM log has $errorCount errors")
      ((totalFailed++))
   fi
else
   echo "⚠ Step $testNum FAIL: $logFile can't be read from the image $imageFull"
   echo "This may happen when building partial stages:"
   echo " -The file may not exist inside the image."
   echo " -Or it may exist but, if the last stage was not built, then it's not found because WM_PROJECT_DIR is not being set on entry."
   echo " In the latter case, then inspect the log file manually"
   failedTests+=("$testNum: OpenFOAM log file not accessible")
   ((totalFailed++))
fi
echo

# --- Step 14: Check OpenFOAM basic functionality (CONTINUE on fail)
((++testNum))
#logFile='$WM_PROJECT_DIR/log.icoFoam'
logFile='$WM_PROJECT_DIR/log.OF_TOOL'
echo "$thisScript: -----------------------------------------"
echo "Step $testNum - Checking that OpenFOAM tool basic output is correct"
echo "Checking the file $logFile"
if docker run --rm "$imageFull" bash -c "[[ -f $logFile ]]" 2>/dev/null; then
   if docker run --rm "$imageFull" bash -c "
    grep -qE '^Usage:' \"$logFile\" &&
    grep -qE '^Options:' \"$logFile\" &&
    grep -qE '^Using: OpenFOAM-${OF_VERSION}' \"$logFile\"
   "; then
      echo "✓ Test $testNum PASS: All required output lines found in $logFile"
      docker run --rm "$imageFull" bash -c "
         grep -E '^Usage:' \"$logFile\";
         grep -E '^Options:' \"$logFile\";
         grep -E '^Using: OpenFOAM-${OF_VERSION}' \"$logFile\"
      "
   else
      echo "✖ Test $testNum FAIL: Missing required output lines in $logFile"
      echo "Missing patterns:"
      docker run --rm "$imageFull" bash -c "
       [[ \$(grep -cE '^Usage:' \"$logFile\") -eq 0 ]] && echo '  - ^Usage:';
       [[ \$(grep -cE '^Options:' \"$logFile\") -eq 0 ]] && echo '  - ^Options:';
       [[ \$(grep -cE '^Using: OpenFOAM-${OF_VERSION}') -eq 0 ]] && echo '  - ^Using: OpenFOAM-${OF_VERSION}'
      "
      failedTests+=("$testNum: OpenFOAM tool basic output incomplete")
      ((totalFailed++))
   fi
else
   echo "⚠ Step $testNum FAIL: $logFile can't be read from the image $imageFull"
   echo "This may happen when building partial stages:"
   echo " -The file may not exist inside the image."
   echo " -Or it may exist but, if the last stage was not built, then it's not found because WM_PROJECT_DIR is not being set on entry."
   echo " In the latter case, then inspect the log file manually"
   failedTests+=("$testNum: OpenFOAM tool basic test log file not accessible")
   ((totalFailed++))
fi 
echo

# --- Final Summary
echo "======================================================"
echo "$thisScript: FINAL SUMMARY"
echo "======================================================"
echo "Total steps run: $testNum"
if [[ $totalFailed -eq 0 ]]; then
   echo "✓ ALL STEPS PASSED! Image '$imageFull' was built successfully."
   echo " Apply minimal test and then perform singularity build."
   exit 0
else
   echo "✖ $totalFailed STEPS(S) FAILED:"
   for test in "${failedTests[@]}"; do
      echo "  - $test"
   done
   exit 1
fi
