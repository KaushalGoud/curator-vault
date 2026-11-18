package main

import (
	"fmt"
	"os"

	"prover/circuits"

	"github.com/brevis-network/brevis-sdk/sdk"
)

func envOr(name, fallback string) string {
	if v := os.Getenv(name); v != "" {
		return v
	}
	return fallback
}

func main() {
	app := &circuits.AppCircuit{}
	ccs, err := sdk.CompileOnly(app)
	if err != nil {
		fmt.Println(err)
		os.Exit(1)
	}

	_, _, vkHash, err := sdk.Setup(ccs, envOr("SRS_DIR", "$HOME/kzgsrs"), 16, 0, 0)
	if err != nil {
		fmt.Println(err)
		os.Exit(1)
	}
	fmt.Printf("0x%x\n", vkHash)
}
