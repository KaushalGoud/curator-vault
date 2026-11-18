package main

import (
	"flag"
	"fmt"
	"os"
	"strconv"

	"prover/circuits"

	"github.com/brevis-network/brevis-sdk/sdk/prover"
)

var port = flag.Uint("port", 33247, "prover service port")

func envOr(name, fallback string) string {
	if v := os.Getenv(name); v != "" {
		return v
	}
	return fallback
}

func main() {
	flag.Parse()

	chainID, err := strconv.Atoi(envOr("CHAIN_ID", "11155111"))
	if err != nil {
		fmt.Println("invalid CHAIN_ID:", err)
		os.Exit(1)
	}

	proverRPC := os.Getenv("PROVER_RPC_URL")
	if proverRPC == "" {
		proverRPC = envOr("RPC_URL", "https://ethereum-sepolia-rpc.publicnode.com")
	}

	service, err := prover.NewService(&circuits.AppCircuit{}, prover.ServiceConfig{
		SetupDir: envOr("SETUP_DIR", "$HOME/circuitOut"),
		SrsDir:   envOr("SRS_DIR", "$HOME/kzgsrs"),
		RpcURL:   proverRPC,
		ChainId:  chainID,
	})
	if err != nil {
		fmt.Println(err)
		os.Exit(1)
	}
	service.Serve("", *port)
}
