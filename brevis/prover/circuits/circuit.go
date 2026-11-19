package circuits

import (
	"github.com/brevis-network/brevis-sdk/sdk"
	"github.com/ethereum/go-ethereum/common"
)

var rebalanceEventID = sdk.ParseEventID(common.FromHex("0x7695179da897f34aafd4fd21192495edfbd07001ccf37cf3a8834e7fa5620077"))

var one = sdk.ConstUint248(1)
var two = sdk.ConstUint248(2)

type AppCircuit struct {
	Hook          sdk.Uint248
	Strategy      sdk.Uint248
	MinRebalances sdk.Uint248
}

var _ sdk.AppCircuit = &AppCircuit{}

func (c *AppCircuit) Allocate() (maxReceipts, maxStorage, maxTransactions int) {
	return 32, 0, 0
}

func (c *AppCircuit) Define(api *sdk.CircuitAPI, in sdk.DataInput) error {
	receipts := sdk.NewDataStream(api, in.Receipts)
	first := sdk.GetUnderlying(receipts, 0)
	second := sdk.GetUnderlying(receipts, 1)

	assertRebalance(api, c, first)
	assertRebalance(api, c, second)

	api.Uint248.AssertIsLessOrEqual(c.MinRebalances, two)

	firstLess := api.Uint32.IsLessThan(first.BlockNum, second.BlockNum)
	minBlock := api.Uint32.Select(firstLess, first.BlockNum, second.BlockNum)
	maxBlock := api.Uint32.Select(firstLess, second.BlockNum, first.BlockNum)

	api.OutputAddress(c.Hook)
	api.OutputAddress(c.Strategy)
	api.OutputUint(64, two)
	api.OutputUint(32, api.ToUint248(minBlock))
	api.OutputUint(32, api.ToUint248(maxBlock))

	return nil
}

func assertRebalance(api *sdk.CircuitAPI, c *AppCircuit, r sdk.Receipt) {
	f := r.Fields[0]
	hookMatches := api.Uint248.IsEqual(f.Contract, c.Hook)
	eventMatches := api.Uint248.IsEqual(f.EventID, rebalanceEventID)
	isTopic := api.Uint248.IsEqual(f.IsTopic, one)
	isStrategyTopic := api.Uint248.IsEqual(f.Index, two)
	strategyMatches := api.Uint248.IsEqual(api.ToUint248(f.Value), c.Strategy)
	valid := api.Uint248.And(hookMatches, eventMatches, isTopic, isStrategyTopic, strategyMatches)
	api.Uint248.AssertIsEqual(valid, one)
}
