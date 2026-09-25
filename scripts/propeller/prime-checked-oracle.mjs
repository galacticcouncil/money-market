// Read-only checked-oracle getters and previews at the market snapshot's block.
import assert from "node:assert/strict";
import { readFileSync, writeFileSync } from "node:fs";
import { createPublicClient, http, parseAbi } from "viem";

const market = JSON.parse(readFileSync(process.argv[2]));
const hydration = JSON.parse(readFileSync(process.argv[3]));
assert.equal(market.hash, hydration.hash);
assert.equal(String(market.block), String(hydration.block));
const address = hydration.receiver.oracles;
assert.equal(
  address.toLowerCase(),
  hydration.oracles.receiverTarget.address.toLowerCase()
);
const blockNumber = BigInt(market.block);
const client = createPublicClient({
  transport: http("https://hdx.tarn.hydration.cloud", { timeout: 120000 }),
});
// Frontier's Ethereum header hash differs from the Substrate snapshot hash.
assert.equal(
  await client.request({
    method: "chain_getBlockHash",
    params: [Number(blockNumber)],
  }),
  market.hash
);
const abi = parseAbi([
  "function checkOracle() view returns(address)",
  "function checkDecimals() view returns(uint8)",
  "function maxDiffBps() view returns(uint256)",
  "function pusher() view returns(address)",
  "function checkPrice() view returns(bool,int256)",
  "function previewSetPrice(int256) view returns(bool,uint256)",
]);
const result = { address, block: String(market.block), checks: {} };
for (const price of [100013124n, 106081891n]) {
  result.checks[String(price)] = await client.readContract({
    address,
    abi,
    blockNumber,
    functionName: "previewSetPrice",
    args: [price],
  });
}
for (const functionName of [
  "checkOracle",
  "checkDecimals",
  "maxDiffBps",
  "pusher",
  "checkPrice",
]) {
  result.checks[functionName] = await client.readContract({
    address,
    abi,
    blockNumber,
    functionName,
  });
}
writeFileSync(
  process.argv[4] || "/tmp/propeller-prime-checked-oracle.json",
  JSON.stringify(
    result,
    (_, v) => (typeof v === "bigint" ? v.toString() : v),
    2
  ) + "\n"
);
console.log(
  JSON.stringify({
    address,
    block: result.block,
    guardBps: String(result.checks.maxDiffBps),
  })
);
