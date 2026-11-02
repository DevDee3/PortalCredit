# Portaldot chain notes

Network details for Portaldot V3 Testnet and the current deployment runbook.

## Testnet network

| Item | Value |
|---|---|
| EVM RPC | `https://test-evm-rpc-v3.portaldot.dev` |
| WebSocket node | `wss://test-node-v3.portaldot.dev` |
| EVM chain ID | `420420777` |
| Node explorer | https://node-console.portaldot.dev/ |

## Verified

- Contracts compile with solc 0.8.24, `evm_version = paris` (no PUSH0).
- 81 tests pass on a standard EVM (Foundry).
- `Deploy.s.sol` deploys and wires the whole system on a local Anvil node and writes
  `contracts/deployments/<chainid>.json`.

## Not yet verified (do before the check-in)

| Question | Why it matters | How to confirm |
|---|---|---|
| Does standard solc EVM bytecode deploy on the V3 testnet? | Public notes describe the Solidity side as `pallet-revive`, which may require a different compiler target (resolc / PolkaVM) instead of plain EVM bytecode. | Deploy a trivial contract with `forge create`. If rejected, use the toolchain the Portaldot V3 repos/Discord point to and report the finding. |
| Testnet RPC URL, chain ID, explorer | Required for deployment and frontend configuration. | Confirmed from the updated Portaldot V3 testnet network information above. |
| How to fund an EVM address | Reports say an EVM address must be funded via its mapped Substrate address. | Official guide and faucet in Discord. |
| Contract size and opcode limits | The vault and engine are medium-sized; limits could force splitting. | Deploy and observe. |
| Does an official DaaS interface exist on testnet? | Would let `IDefaultResolver` adapt to it. None was publicly documented. | Ask in Discord / kickoff notes. |
| Timestamp behaviour | Auction pricing and windows use `block.timestamp`. | Check block time and monotonicity on testnet. |

## Testnet deploy runbook

Run from a machine that can reach the testnet RPC.

```bash
# 1. install Foundry (https://getfoundry.sh) and clone the repo
cd contracts

# 2. configure (use --account with an encrypted keystore, or PRIVATE_KEY)
export DEPLOYER=<deployer address>             # public address used with --account
export SEED_LIQUIDITY=10000000000              # optional: 10,000 pcUSD as first LP
export DEMO_WINDOWS=true                      # minutes-long windows so the lifecycle can be shown live

# 3. sanity check with a trivial deployment first, then deploy the system
forge script script/Deploy.s.sol --account <account name> --rpc-url portaldot_testnet --chain-id 420420777 --broadcast

# 4. addresses are written to deployments/<chainid>.json; commit that file and paste the tx hashes into the README
```

If `forge script` fails with a bytecode or gas-estimation error, record the exact error here. It is the most
valuable fact we can learn early, and it decides whether a different compiler target is needed.
