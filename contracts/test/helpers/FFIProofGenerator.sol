// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Vm} from "forge-std/Vm.sol";

/**
 * @title FFIProofGenerator
 * @notice Generates real merkle proofs using Go FFI, similar to Optimism's approach
 */
library FFIProofGenerator {
    Vm internal constant vm = Vm(0x7109709ECfa91a80626fF3989D68f67F5b1DD12D);
    
    /**
     * @notice Generate a merkle proof for a withdrawal using Go FFI
     * @param withdrawalHash The hash of the withdrawal to prove
     * @return storageRoot The storage root of the message passer
     * @return proof The merkle proof
     */
    function generateWithdrawalProof(
        bytes32 withdrawalHash
    ) internal returns (bytes32 storageRoot, bytes[] memory proof) {
        string[] memory cmds = new string[](3);
        cmds[0] = "scripts/go-ffi/go-ffi-bin";
        cmds[1] = "getWithdrawalProof";
        cmds[2] = vm.toString(withdrawalHash);
        
        bytes memory result = vm.ffi(cmds);
        (storageRoot, proof) = abi.decode(result, (bytes32, bytes[]));
    }
}