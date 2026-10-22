# Portaldot chain notes

Honest status of what we know about running this on Portaldot V3. Update this file as the facts are confirmed.

## Verified

- Contracts compile with solc 0.8.24, `evm_version = paris` (no PUSH0).
- 81 tests pass on a standard EVM (Foundry).
- `Deploy.s.sol` deploys and wires the whole system on a local Anvil node and writes
  `contracts/deployments/<chainid>.json`.

## Not yet verified (do before the check-in)

| Question | Why it matters | How to confirm |
|---|---|---|
| Does standard solc EVM bytecode deploy on the V3 testnet? | Public notes describe the Solidity side as `pallet-revive`, which may require a different compiler target (resolc / PolkaVM) instead of plain EVM bytecode. | Deploy a trivial contract with `forge create`. If rejected, use the toolchain the Portaldot V3 repos/Discord point to and report the finding. |
| Testnet RPC URL, chain ID, explorer | Needed for `foundry.toml` and the frontend. A candidate RPC URL circulated but was not reachable from our build sandbox, so it is unconfirmed. | Official Discord (`discord.gg/portaldot`) and the V3 GitHub repos. |
| How to fund an EVM address | Reports say an EVM address must be funded via its mapped Substrate address. | Official guide and faucet in Discord. |
| Contract size and opcode limits | The vault and engine are medium-sized; limits could force splitting. | Deploy and observe. |
| Does an official DaaS interface exist on testnet? | Would let `IDefaultResolver` adapt to it. None was publicly documented. | Ask in Discord / kickoff notes. |
| Timestamp behaviour | Auction pricing and windows use `block.timestamp`. | Check block time and monotonicity on testnet. |

## Testnet deploy runbook

Run from a machine that can reach the testnet RPC.

```bash
# 1. install Foundry (https://getfoundry.sh) and clone the repo
cd contracts

# 2. configure
export RPC_URL=<portaldot testnet rpc>
export PRIVATE_KEY=<funded deployer key>      # never commit this
export SEED_LIQUIDITY=10000000000              # optional: 10,000 pcUSD as first LP
export DEMO_WINDOWS=true                       # minutes-long windows so the lifecycle can be shown live

# 3. sanity check with a trivial deployment first, then deploy the system
forge script script/Deploy.s.sol --rpc-url $RPC_URL --broadcast

# 4. addresses are written to deployments/<chainid>.json; commit that file and paste the tx hashes into the README
```

If `forge script` fails with a bytecode or gas-estimation error, record the exact error here. It is the most
valuable fact we can learn early, and it decides whether a different compiler target is needed.
