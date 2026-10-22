# Security notes and known limitations

This is a hackathon prototype. It has not been audited. The test suite (81 tests, including 5 stateful invariants
under random action sequences) is evidence of intended behaviour, not a guarantee.

## What is enforced

- Reentrancy: state-changing vault and engine entry points use `nonReentrant`; effects precede interactions.
- Collateral custody: a financed `ReceivableNFT` can move only vault <-> engine (checked in `_update`, so every
  transfer path is covered). Invariants assert custody follows loan state.
- Solvency accounting: `idleCash` is tracked internally; tests assert the vault holds at least that much, that
  aggregate counters equal the sum over loans, and that LP claims never exceed assets.
- Inflation attack: 6-decimal virtual share offset; covered by a test.
- Failure isolation: resolver hooks are wrapped in try/catch, so a broken resolver cannot block seizure or
  liquidation. Only an explicit `false` from `validateDefault` vetoes a seizure. `setResolver` rejects
  non-contract addresses, because a failed decode of empty return data would not be caught.
- Liveness: if the resolver never rules on a dispute, anyone can call `expireDispute` after the timeout.
- Parameter bounds: every owner setter has an upper bound; the engine and vault can be paused.

## Trust assumptions and limitations

1. **Centralised arbiter.** `ArbiterResolver` is owner-controlled. Whoever owns it decides disputes and can veto
   a seizure. In production this must be a multisig or an external protocol (the intended role of DaaS).
2. **Owner powers.** The owner can change fee, advance-rate and window parameters within bounds, pause the system,
   and write off a liquidated loan early. It cannot move LP funds or collateral directly.
3. **Off-chain truth.** Receivable validity (that the invoice is real and the obligor will pay) is not verified
   on-chain. `obligor` is an opaque hash. An RWA deployment needs legal structure, KYC and an attestation layer.
4. **No interest accrual or late penalties.** Yield is a flat origination fee. Overdue loans do not accrue more.
5. **Auction pricing.** The Dutch auction depends on a buyer showing up; price decays to a floor of 40% of debt
   and LPs bear the resulting shortfall. There is no oracle-based fair-value check.
6. **Single-asset, 6-decimal assumption.** The vault is designed around a 6-decimal stablecoin. Fee-on-transfer
   or rebasing tokens are unsupported.
7. **Gas / chain behaviour unverified on Portaldot V3.** Behaviour was tested on a standard EVM (Foundry/Anvil).
   See `chain-notes.md`.
8. **`MockStable` is a faucet token** and must never be used outside testnets.

## Not yet done

- External audit and formal verification.
- Fork or testnet-based fuzzing against the real Portaldot runtime.
- Gas profiling on the target chain.
