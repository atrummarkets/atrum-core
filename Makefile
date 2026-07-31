# Atrum core -- build, test and measurement entry points.
#
# Monad Foundry is REQUIRED. Stock Foundry produces wrong gas numbers because
# Monad reprices BN254 ~5x and cold SLOAD 4x. It is installed to a separate
# prefix so it does not shadow a stock Foundry install.
#
# Note: upstream foundry-rs `foundryup` silently IGNORES `--network monad`.
# The Monad fork's installer lives at https://foundry.category.xyz and its
# `foundryup` still needs `--network monad` passed explicitly.

MONAD_FOUNDRY := $(HOME)/.foundry-monad/bin
FORGE         := $(MONAD_FOUNDRY)/forge
NETWORK       ?= testnet

.PHONY: help
help:
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) \
		| awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-18s\033[0m %s\n", $$1, $$2}'

# ---------------------------------------------------------------------------
# Contracts
# ---------------------------------------------------------------------------

.PHONY: build
build: ## Compile contracts with Monad Foundry
	cd contracts && $(FORGE) build

.PHONY: test
test: ## Run the contract test suite under the Monad gas schedule
	cd contracts && $(FORGE) test --network monad

.PHONY: checkup
checkup: ## READABLE WALKTHROUGH: every function, ok/FAIL per call, real proofs
	cd contracts && $(FORGE) test --network monad --match-test test_checkup_everything -vv

.PHONY: checkup-part
checkup-part: ## One area: PART=vault|tree|shieldedPool|parimutuel|security
	cd contracts && $(FORGE) test --network monad --match-test test_checkup_$(PART) -vv

.PHONY: gas
gas: ## Contract gas report
	cd contracts && $(FORGE) test --network monad --gas-report

.PHONY: fmt
fmt: ## Format Solidity
	cd contracts && $(FORGE) fmt

# ---------------------------------------------------------------------------
# Circuits
# ---------------------------------------------------------------------------

.PHONY: circuits
circuits: ## Compile circuits, run Groth16 setup, export Solidity verifiers
	cd circuits && ./scripts/build.sh

.PHONY: keygen
keygen: ## Generate a BabyJubJub committee keypair (TEST USE ONLY)
	cd circuits && node scripts/keygen.mjs

.PHONY: prove
prove: ## Generate proofs and verify the ElGamal mechanism end to end
	cd circuits && node scripts/prove.mjs

.PHONY: fixtures
fixtures: ## Real deposit/bet/redeem proofs for the Solidity suite to replay
	cd circuits && node scripts/gen_action_fixtures.mjs
	cd circuits && node scripts/gen_settlement_fixtures.mjs
	# Must run AFTER gen_action_fixtures: it settles the ciphertext those real bets produced.
	cd circuits && node scripts/gen_e2e_fixtures.mjs

.PHONY: verifiers
verifiers: ## Copy generated verifiers into contracts/src/verifiers and build
	@mkdir -p contracts/src/verifiers
	@for pair in "probe_fixed_key:FixedKeyVerifier" "probe_pubkey_input:PubKeyInputVerifier" \
	             "deposit:DepositVerifier" "bet:BetVerifier" "redeem:RedeemVerifier" \
	             "bet_encrypted:BetEncryptedVerifier" "redeem_private:RedeemPrivateVerifier" "withdraw:WithdrawVerifier"; do \
		src="$${pair%%:*}"; name="$${pair##*:}"; \
		sed "s/contract Groth16Verifier/contract $$name/" \
			"circuits/build/$${src}_verifier.sol" > "contracts/src/verifiers/$${name}.sol"; \
		echo "wrote contracts/src/verifiers/$${name}.sol"; \
	done
	cd contracts && $(FORGE) build

# ---------------------------------------------------------------------------
# Measurement -- against live Monad nodes, no key and no spend
# ---------------------------------------------------------------------------

.PHONY: measure
measure: ## Chain params + precompile costs (NETWORK=testnet|mainnet)
	python3 tools/monad_gas.py all --network $(NETWORK)

.PHONY: gate
gate: ## PHASE 0 GATE: real Groth16 verify gas vs the 1.5M stop-line
	python3 tools/measure_verifier.py --network $(NETWORK)

.PHONY: poseidon
poseidon: ## PHASE 1 GATE (part 1): on-chain Poseidon cost, live chain
	python3 tools/measure_poseidon.py --network $(NETWORK)

.PHONY: uniformity
uniformity: ## CI ANTI-FINGERPRINTING GUARD: every action fits ONE declared gas limit
	@mkdir -p circuits/build
	python3 tools/measure_verifier.py --network $(NETWORK) \
		--json circuits/build/gate-$(NETWORK).json
	python3 tools/check_gas_uniformity.py circuits/build/gate-$(NETWORK).json

.PHONY: verify-all
verify-all: prove fixtures test gate uniformity ## Everything that can fail, in dependency order

# ---------------------------------------------------------------------------

.PHONY: clean
clean: ## Remove build artefacts (keeps the downloaded ptau)
	rm -rf contracts/out contracts/cache
	rm -rf circuits/build/*_js circuits/build/*.r1cs circuits/build/*.sym \
	       circuits/build/*.zkey circuits/build/*_verifier.sol
