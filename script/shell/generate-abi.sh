#!/usr/bin/env bash

# Pre-requisites:
# - foundry (https://getfoundry.sh)

set -euo pipefail

abi_dir="./abi"
declare -a contracts=(
    "src/DiamondNames.sol"
    "src/DiamondRegistrarController.sol"
    "src/DiamondRegistry.sol"
)

mkdir -p abi

echo "Building..."

if forge build > /dev/null 2>&1 ; then
    echo "Build finished."
else
    echo "Build failed"
    exit 1
fi

for i in "${!contracts[@]}"
do
    contract=$(basename "${contracts[i]}" .sol)
    echo "[$((i+1))/${#contracts[@]}] Generating ABI for $contract"
    forge inspect "${contracts[i]}" abi --json > "${abi_dir}/${contract}.json"
done
