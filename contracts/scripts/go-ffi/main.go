package main

import (
	"fmt"
	"math/big"
	"os"

	"github.com/ethereum/go-ethereum/accounts/abi"
	"github.com/ethereum/go-ethereum/common"
	"github.com/ethereum/go-ethereum/common/hexutil"
	"github.com/ethereum/go-ethereum/core/rawdb"
	"github.com/ethereum/go-ethereum/core/types"
	"github.com/ethereum/go-ethereum/crypto"
	"github.com/ethereum/go-ethereum/trie"
	"github.com/ethereum/go-ethereum/triedb"
	"github.com/ethereum/go-ethereum/triedb/hashdb"
)

// Adapted from Optimism's go-ffi for OP Succinct bridge tests

// Custom type to collect proof nodes
type proofList [][]byte

func (n *proofList) Put(key []byte, value []byte) error {
	*n = append(*n, value)
	return nil
}

func (n *proofList) Delete(key []byte) error {
	panic("not supported")
}

func main() {
	if len(os.Args) < 2 {
		panic("Must provide a command")
	}

	cmd := os.Args[1]
	switch cmd {
	case "getWithdrawalProof":
		if len(os.Args) != 3 {
			panic("getWithdrawalProof requires withdrawalHash argument")
		}
		getWithdrawalProof()
	default:
		panic(fmt.Sprintf("Unknown command: %s", cmd))
	}
}

// getWithdrawalProof generates a merkle proof for a withdrawal
func getWithdrawalProof() {
	// Parse withdrawal hash from command line
	withdrawalHashHex := os.Args[2]
	withdrawalHash := common.HexToHash(withdrawalHashHex)

	// Storage slot is keccak256(withdrawalHash || uint256(0))
	// Pack the slot data
	uint256Type, _ := abi.NewType("uint256", "", nil)
	bytes32Type, _ := abi.NewType("bytes32", "", nil)
	
	args := abi.Arguments{
		{Type: bytes32Type},
		{Type: uint256Type},
	}
	
	packed, err := args.Pack(withdrawalHash, big.NewInt(0))
	if err != nil {
		panic(err)
	}

	// Calculate storage key (this is the storage slot)
	storageKey := crypto.Keccak256Hash(packed)

	// Create a secure trie for the message passer storage
	storage, err := trie.NewStateTrie(
		trie.TrieID(types.EmptyRootHash),
		triedb.NewDatabase(rawdb.NewMemoryDatabase(), &triedb.Config{HashDB: hashdb.Defaults}),
	)
	if err != nil {
		panic(err)
	}

	// Store value 0x01 (true) at the storage key
	// The storage trie uses the raw storageKey bytes as the key
	err = storage.UpdateStorage(common.Address{}, storageKey.Bytes(), []byte{0x01})
	if err != nil {
		panic(err)
	}

	// Generate proof for the storage key
	var proof proofList
	err = storage.Prove(storageKey.Bytes(), &proof)
	if err != nil {
		panic(err)
	}

	// Get the storage root
	storageRoot, _ := storage.Commit(false)

	// Output format: storageRoot, proof[]
	// Pack the output
	bytes32Type, _ = abi.NewType("bytes32", "", nil)
	bytesArrayType, _ := abi.NewType("bytes[]", "", nil)

	outputArgs := abi.Arguments{
		{Type: bytes32Type},
		{Type: bytesArrayType},
	}

	output, err := outputArgs.Pack(storageRoot, [][]byte(proof))
	if err != nil {
		panic(err)
	}

	// Print hex encoded output
	fmt.Print(hexutil.Encode(output))
}

// Helper to check errors
func checkErr(err error, msg string) {
	if err != nil {
		panic(fmt.Sprintf("%s: %v", msg, err))
	}
}