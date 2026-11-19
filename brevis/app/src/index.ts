import {
  Brevis,
  ErrCode,
  Field,
  ProofRequest,
  Prover,
  ReceiptData,
  asUint248,
} from 'brevis-sdk-typescript';
import { ethers } from 'ethers';

const required = (name: string): string => {
  const value = process.env[name];
  if (!value) throw new Error(`missing ${name}`);
  return value;
};

const optional = (name: string, fallback: string): string => process.env[name] || fallback;

const ZK_MODE = 0;
const EVENT_ID =
  '0x7695179da897f34aafd4fd21192495edfbd07001ccf37cf3a8834e7fa5620077';

const REQUEST_ABI = [
  'function sendRequest(bytes32 _proofId, uint64 _nonce, address _refundee, tuple(address target, uint64 gas) _callback, uint8 _option) payable',
];

async function main() {
  const prover = new Prover(optional('PROVER', 'localhost:33247'));
  const gatewayUrl = optional('GATEWAY', 'appsdkv2.brevis.network:9094');
  const brevis = new Brevis(gatewayUrl);

  const verifier = required('VERIFIER');
  const hook = required('HOOK');
  const strategy = required('STRATEGY');
  const minRebalances = optional('MIN_REBALANCES', '2');
  const srcChainId = Number(optional('SRC_CHAIN_ID', '11155111'));
  const dstChainId = Number(optional('DST_CHAIN_ID', '11155111'));
  const partnerKey = optional('PARTNER_KEY', '');
  const brevisRequest = optional('BREVIS_REQUEST', '0x841ce48F9446C8E281D3F1444cB859b4A6D0738C');
  const callbackGas = Number(optional('CALLBACK_GAS', '500000'));

  const baseTxHashes = required('TX_HASHES')
    .split(',')
    .map((tx) => tx.trim())
    .filter((tx) => tx.length > 0);
  const baseLogPositions = optional('LOG_POS', '0')
    .split(',')
    .map((value) => Number(value.trim()))
    .filter((value) => Number.isInteger(value) && value >= 0);
  const maxReceipts = Number(optional('MAX_RECEIPTS', '32'));

  if (baseTxHashes.length === 0) throw new Error('TX_HASHES is empty');
  if (!Number.isInteger(maxReceipts) || maxReceipts <= 0) {
    throw new Error('invalid MAX_RECEIPTS');
  }
  if (baseTxHashes.length > maxReceipts) throw new Error('too many TX_HASHES');
  if (baseLogPositions.length === 1) {
    while (baseLogPositions.length < baseTxHashes.length) {
      baseLogPositions.push(baseLogPositions[0]);
    }
  }
  if (baseLogPositions.length !== baseTxHashes.length) {
    throw new Error('LOG_POS must have one value or one value per TX_HASH');
  }

  const fields = baseTxHashes.map((txHash, i) => ({
    txHash,
    logPos: baseLogPositions[i],
    fieldIndex: 2,
  }));
  while (fields.length < maxReceipts) {
    const idx = fields.length % baseTxHashes.length;
    fields.push({
      txHash: baseTxHashes[idx],
      logPos: baseLogPositions[idx],
      fieldIndex: 2,
    });
  }

  const proofReq = new ProofRequest();
  for (let i = 0; i < fields.length; i++) {
    const field = fields[i];
    if (
      !ethers.utils.isHexString(field.txHash) ||
      ethers.utils.hexDataLength(field.txHash) !== 32
    ) {
      throw new Error(`invalid tx hash ${field.txHash}`);
    }
    proofReq.addReceipt(
      new ReceiptData({
        tx_hash: field.txHash,
        fields: [
          new Field({
            contract: hook,
            log_index: field.logPos,
            event_id: EVENT_ID,
            is_topic: true,
            field_index: field.fieldIndex,
            value: strategy,
          }),
        ],
      }),
      i,
    );
  }

  proofReq.setCustomInput({
    Hook: asUint248(hook),
    Strategy: asUint248(strategy),
    MinRebalances: asUint248(minRebalances),
  });

  const proofRes = await prover.prove(proofReq);
  if (proofRes.has_err) {
    const err = proofRes.err;
    if (err) {
      console.error(`prover error ${err.code}: ${err.msg}`);
    }
    return;
  }

  const submitRes = await brevis.submit(
    proofReq,
    proofRes,
    srcChainId,
    dstChainId,
    ZK_MODE,
    partnerKey,
    verifier,
  );

  if (!partnerKey) {
    const provider = new ethers.providers.JsonRpcProvider(required('RPC_URL'));
    const wallet = new ethers.Wallet(required('PRIVATE_KEY'), provider);
    const request = new ethers.Contract(brevisRequest, REQUEST_ABI, wallet);
    const tx = await request.sendRequest(
      submitRes.queryKey.query_hash,
      submitRes.queryKey.nonce,
      wallet.address,
      [verifier, callbackGas],
      ZK_MODE,
      { value: submitRes.fee },
    );
    await tx.wait();
    console.log(`Brevis request sent ${tx.hash}`);
  }

  const result = await brevis.wait(submitRes.queryKey, dstChainId);
  console.log(result);
  if (!result.success) process.exitCode = 1;
}

void main().catch((err) => {
  console.error(err);
  process.exitCode = 1;
});
