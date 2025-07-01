#!/bin/bash
# Manual verification script for CREATE2 deployed contracts

# SP1MockVerifier
forge verify-contract \
    0xafBB3c1542A9A2f2D44Ae5D445094CC97a17d428 \
    SP1MockVerifier \
    --etherscan-api-key $ETHERSCAN_API_KEY \
    --chain sepolia \
    --watch

# Rollup  
forge verify-contract \
    0xaF3A795AD48d51B850CA18fC529F53a75Ec62c30 \
    Rollup \
    --constructor-args $(cast abi-encode "constructor(uint256,uint256,uint256,uint256,uint256,bytes32,uint128,address,bytes32,bytes32,bytes32,address)" 604800 16200 1000000000000000 1000000000000000 75000 0xe17988e5b58cb378cc4ece3eed3812f0c1af2862c3c40c50491142f3afe6882d 1513550 0xafBB3c1542A9A2f2D44Ae5D445094CC97a17d428 0x0000000000000000000000000000000000000000000000000000000000000000 0x0000000000000000000000000000000000000000000000000000000000000000 0x0000000000000000000000000000000000000000000000000000000000000000 0x97810BC796b9C25515c4a5eDF91e81407ADc5709) \
    --etherscan-api-key $ETHERSCAN_API_KEY \
    --chain sepolia \
    --watch