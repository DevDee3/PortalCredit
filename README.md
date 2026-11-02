# PortalCredit

**An RWA credit vault with a fully on-chain default lifecycle, built for the Portaldot Hacker House 2026
(Ecosystem DApps track).**

Borrowers finance invoices as NFTs. LPs fund an ERC-4626 vault. When a loan goes bad, a permissionless state
machine handles dispute, seizure, Dutch-auction liquidation and loss allocation, so LPs see losses the moment a
default is confirmed and anyone can keep the system moving. The resolver is pluggable (`IDefaultResolver`), so
Portaldot's DaaS protocol can be adopted as the default-resolution backend once an interface is available.

> Status: contracts, tests, deploy script, docs and the Next.js frontend are done. Portaldot testnet deployment is
> in progress. See [Status](#status) for exactly what is verified.

## Why Portaldot

Portaldot's own protocol stack is built around DaaS (Default-as-a-Service) for RWA, DeFi and cross-chain
settlement. PortalCredit is the application layer for that thesis: a credit product where default handling is the
core feature, not an afterthought. Portaldot V3's EVM support alongside WASM is what makes a Solidity credit vault
possible on the network.

## How it works

1. A borrower mints a `ReceivableNFT` for an invoice (face value, due date, obligor hash).
2. They `advance` against it: the vault lends 80% of face and locks the NFT.
3. They `repay` principal plus a 2% origination fee. The NFT is released. LPs earn the fee.
4. If they do not repay, anyone can `flagOverdue` after the grace period. The borrower may `dispute` once; a
   resolver rules. Otherwise anyone can `seize` the collateral and `liquidate` it in a Dutch auction.
5. The vault writes the loan down to its expected recovery at seizure and books the real result at liquidation.
   Late recoveries can be credited back to LPs with `recover`; remaining losses are accepted with `writeOff`.

See [docs/architecture.md](docs/architecture.md) for diagrams, accounting and parameters.

## Repository layout

```
contracts/            Foundry project
  src/                ReceivableNFT, CreditVault, DefaultEngine, ArbiterResolver, MockStable, interfaces
  test/               81 tests: unit, fuzz, access-control and stateful invariants
  script/Deploy.s.sol deploy + wire + write deployments/<chainid>.json
web/                  Next.js + wagmi/viem app (vault, borrower and loan-lifecycle pages)
  scripts/e2e.mts     end-to-end smoke test of the app's ABIs against a deployment
docs/
  architecture.md     components, lifecycle, sequence, accounting, parameters
  security.md         guarantees, trust assumptions, known limitations
  chain-notes.md      what is verified on Portaldot vs not yet, testnet runbook
contracts/lib/        vendored OpenZeppelin v5.1.0 and forge-std (see Third-party code)
```

## Run it

Requirements: [Foundry](https://getfoundry.sh).

```bash
cd contracts
forge test                      # 81 tests
forge coverage --no-match-coverage "(test|script)"   # 100% lines, statements, branches, functions on src/
forge test --match-contract InvariantTest -vv

# local demo deployment
anvil &
PRIVATE_KEY=<anvil key> SEED_LIQUIDITY=10000000000 DEMO_WINDOWS=true \
  forge script script/Deploy.s.sol --rpc-url http://127.0.0.1:8545 --broadcast
```

Frontend (point it at any deployment through `web/.env.local`, see `web/.env.example`):

```bash
cd web
npm install
npm run dev                     # http://localhost:3000
node --experimental-strip-types scripts/e2e.mts   # full advance/repay/default/liquidate flow against the node
```

Testnet deployment steps are in [docs/chain-notes.md](docs/chain-notes.md).

To deploy the contracts to Portaldot V3 Testnet from `contracts/`, use either a
private key or an encrypted Foundry keystore account. For a keystore account,
provide the account's public address in `DEPLOYER`:

```bash
DEPLOYER=<deployer address> forge script script/Deploy.s.sol \
  --account <account name> \
  --rpc-url portaldot_testnet --chain-id 420420777 --broadcast
```

## Status

| Item | State |
|---|---|
| Contracts | Done. Compile with solc 0.8.24, `evm_version = paris` |
| Tests | 81 passing on a standard EVM (unit, fuzz, access control, 5 stateful invariants). 100% line, statement, branch and function coverage of `src/` |
| Local deployment | Verified on Anvil |
| Portaldot testnet deployment | **Not done yet.** Addresses and tx hashes will be added here |
| Frontend (Next.js) | Done: vault, borrow and loan pages, wallet connect, faucet. Production build passes; e2e script passes on Anvil |
| Audit | None. Prototype. See [docs/security.md](docs/security.md) |

## Testnet deployment

_Pending. Contract addresses, transaction hashes and explorer links will be listed here once deployed._

## Third-party code

- [OpenZeppelin Contracts](https://github.com/OpenZeppelin/openzeppelin-contracts) v5.1.0 (MIT): ERC-20, ERC-721,
  ERC-4626, Ownable, Pausable, ReentrancyGuard, SafeERC20, SafeCast, Math
- [forge-std](https://github.com/foundry-rs/forge-std) (MIT / Apache-2.0): Foundry test and script helpers
- Development tooling used AI assistance (Claude). All code in this repository was written during the Hacker House
  period.

## License

This project is licensed under the [MIT License](LICENSE).
