#!/usr/bin/env bash
# keeper e2e on anvil: 250k split into 3 pieces, pool trimmed before the principal
# payouts. LIQUIDITY=100000 (default): one cycle pays all three by recycling between
# payouts. LIQUIDITY=50000: less than one piece, so the keeper must wait, sending nothing.
#   usage: [LIQUIDITY=50000] bash keeper/e2e-recycle.sh        (from bil-vault/)
set -euo pipefail
cd "$(dirname "$0")/.."
RPC=http://127.0.0.1:8546
ADMIN_PK=0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80   # anvil #0
KEEPER_PK=0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d  # anvil #1
SCRIPT=script/KeeperRecycleScenario.s.sol:KeeperRecycleScenario
LIQUIDITY=${LIQUIDITY:-100000}

# the keeper reads wall-clock time, so start the chain 61 days back and step it to now
NOW=$(date +%s)
anvil --port 8546 --chain-id 222222 --silent --code-size-limit 50000 --timestamp $((NOW - 61 * 86400 - 7200)) &
ANVIL=$!
trap 'kill $ANVIL 2>/dev/null' EXIT
sleep 2

fs() { forge script "$SCRIPT" --rpc-url $RPC --private-key $ADMIN_PK --broadcast --slow "$@" 2>&1; }
out=$(fs --sig "setup()")
VAULT=$(grep -oE "VAULT 0x[0-9a-fA-F]{40}" <<<"$out" | cut -d' ' -f2)
HOLLAR=$(grep -oE "HOLLAR 0x[0-9a-fA-F]{40}" <<<"$out" | cut -d' ' -f2)
echo "vault $VAULT  positions $(cast call --rpc-url $RPC $VAULT 'getPositionCount()(uint256)')"

TXS=0
keeper_cycle() {
  local n0 n1
  n0=$(cast nonce --rpc-url $RPC $(cast wallet address $KEEPER_PK))
  RPC_URL=$RPC VAULT_ADDRESS=$VAULT KEEPER_PRIVATE_KEY=$KEEPER_PK POLL_INTERVAL_MS=600000 ALERT_WEBHOOK= \
    timeout 90 npx tsx keeper/src/index.ts 2>&1 | sed -n '/Running keeper cycle/,/Cycle complete/p' | grep -E "Position|pokeQueue|Calling|waiting" || true
  n1=$(cast nonce --rpc-url $RPC $(cast wallet address $KEEPER_PK))
  TXS=$((n1 - n0))
  echo "  keeper txs this cycle: $TXS"
}
states() { for i in 0 1 2; do cast call --rpc-url $RPC $VAULT 'getPosition(uint256)(uint256,uint256,uint256,uint256,uint256,uint8)' $i | tail -1; done | tr '\n' ' '; echo; }

at() { cast rpc --rpc-url $RPC evm_setNextBlockTimestamp $1 >/dev/null; cast rpc --rpc-url $RPC evm_mine >/dev/null; }
at $((NOW - 7200))   # matured (deposit + 60d), principal delay still ahead
echo "== cycle 1: matured, request yield"; keeper_cycle; echo "  states: $(states)"
fs --sig "approveYields(address)" $VAULT >/dev/null
echo "== cycle 2: execute yield, request principal"; keeper_cycle; echo "  states: $(states)"
fs --sig "approvePrincipals(address,address,uint256)" $VAULT $HOLLAR "${LIQUIDITY}000000000000000000" >/dev/null
at $(( $(date +%s) + 5 ))   # principal requested ~2h ago on-chain, 1h delay passed
echo "  pool liquidity: $(cast call --rpc-url $RPC $HOLLAR 'balanceOf(address)(uint256)' $(cast call --rpc-url $RPC $VAULT 'positionPool(uint256)(address)' 0))"
echo "== cycle 3: principal with a ${LIQUIDITY} pool"; keeper_cycle
s=$(states); echo "  states: $s"
if [ "$LIQUIDITY" -ge 83334 ]; then
  [ "$s" = "4 4 4 " ] && echo "PASS all three pieces redeemed in one cycle" || { echo "FAIL expected 4 4 4"; exit 1; }
else
  [ "$s" = "3 3 3 " ] && [ "$TXS" = 0 ] && echo "PASS keeper waits for liquidity, no paid no-ops" || { echo "FAIL expected 3 3 3 and 0 txs"; exit 1; }
  # the watchdog must blame Decentral (liquidity), never the keeper
  wd=$(RPC_URL=$RPC VAULT_ADDRESS=$VAULT ALERT_WEBHOOK= PORT=0 CLAIM_GRACE_MINUTES=0 timeout 60 npx tsx watchdog/src/index.ts 2>&1 | head -12 || true)
  grep -q "open issues:" <<<"$wd" || { echo "FAIL watchdog did not scan"; echo "$wd"; exit 1; }
  if grep -q "Keeper not advancing" <<<"$wd"; then echo "FAIL watchdog blames the keeper"; echo "$wd"; exit 1; fi
  echo "PASS watchdog does not blame the keeper for a liquidity wait"
fi
