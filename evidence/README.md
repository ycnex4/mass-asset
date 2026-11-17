# Release evidence — Mass Asset v1.0

Program `MAssXtCndQhigtQDDpwkwrUiSQbjT1jkkrXoXzZEtUp` on X1 mainnet, final and verified (`deployment.txt`).

| File | What |
|---|---|
| `mass_asset_v1.sha256` | verifiable build record: commit `d209d04`, image digest, executable hash, `release_build: yes` |
| `testnet-v1-rc-pass.log` | step 3: the conformance suite on X1 testnet against the preview carrying this exact bytecode |
| `candidate-testnet-suite.log` | the same testnet log as frozen by `deploy-candidate.sh` (its sha256 is in `candidate.txt`) |
| `candidate.txt` | step 4: the mainnet candidate (ProgramData, deployment slot, upgrade authority, hash) |
| `mainnet-suite-pass.log` | step 5: the conformance suite on X1 mainnet against the candidate |
| `flux-mainnet-check.log` | step 6: test FLUX release on X1 mainnet against the candidate (288 finalized transactions) |
| `testnet-finalize-rehearsal-eaf9061.log` | rehearsal of the finalization transaction on testnet with the final `finalize-tx.mjs` |
| `finalize/attempt-…/` | step 7: intent, frozen logs, signed transaction record, run output, `CLOSED`, `deployment.txt` |
| `deployment.txt` | the final record: authority none, finalization transaction and slot, hashes of every input |

All transactions referenced in these logs can be looked up on X1 by signature.
