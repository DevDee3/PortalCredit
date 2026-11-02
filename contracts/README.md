# PortalCredit contracts

Foundry project (solc 0.8.24, EVM `paris`, OpenZeppelin v5.1.0 vendored in `lib/`).

```
src/        CreditVault (ERC-4626), DefaultEngine, ReceivableNFT, ArbiterResolver, MockStable, interfaces
test/       unit, fuzz, adversarial LP-timing, access-control and invariant tests (109)
script/     Deploy.s.sol, deploys and wires everything, writes deployments/<chainid>.json
```

## Verify

```bash
forge test                                              # 109 tests
forge coverage --no-match-coverage "(test|script)"      # 100% lines, statements, branches, functions of src/
npx solhint 'src/**/*.sol'                              # config: .solhint.json
slither src/CreditVault.sol --compile-force-framework solc \
  --solc-remaps "@openzeppelin/contracts/=lib/openzeppelin-contracts/contracts/" \
  --solc-args "--evm-version paris --optimize --optimize-runs 200" --filter-paths "lib/"
```

## Deploy

```bash
export PRIVATE_KEY=<deployer key>        # the script currently reads PRIVATE_KEY from the environment
export SEED_LIQUIDITY=10000000000        # optional: 10,000 pcUSD as the first LP
export DEMO_WINDOWS=true                 # optional: minutes-long grace/dispute/auction windows
forge script script/Deploy.s.sol --rpc-url <rpc> --broadcast --legacy
```

Portaldot V3 testnet: EVM RPC `https://test-evm-rpc-v3.portaldot.dev`, chain ID `420420777`. Contract creation on that
chain is not yet confirmed to work with plain solc bytecode; see the main repo's `docs/chain-notes.md`.

## Behaviour worth knowing

- A loan is written down to the auction floor as soon as it is recognised as overdue (flagged, or by the vault's
  own sync before any deposit/withdraw). Redemptions are closed while an unrecognised overdue loan exists, and
  deposits are closed while any write-down is open. `sync(n)` is permissionless.
- Not audited. `ArbiterResolver` is owner-controlled; `MockStable` is a faucet token for testnets only.
