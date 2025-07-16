#!/bin/bash
# Build the Go FFI program for proof generation

cd "$(dirname "$0")/go-ffi"
go build -o go-ffi main.go
chmod +x go-ffi
echo "Built go-ffi binary at $(pwd)/go-ffi"