# Security Testing & Audit Guide

This document describes the security testing tools and processes for The Guild DAO contracts.

## Available Tools

### 1. **Slither** - Static Analysis
Slither is a Solidity static analysis framework that detects vulnerabilities and code quality issues.

**Run Slither:**
```bash
npm run slither
# or directly:
slither .
```

**What it detects:**
- Reentrancy vulnerabilities
- Unprotected state variable changes
- Incorrect modifier usage
- Uninitialized storage pointers
- Dangerous delegatecall usage
- Integer overflow/underflow (pre-0.8.0)
- Access control issues
- And 90+ other detector types

**Output:** Categorized findings (High, Medium, Low, Informational)

---

### 2. **Solhint** - Security Linting
Solhint enforces security and style best practices for Solidity code.

**Run Solhint:**
```bash
npm run lint          # Check for issues
npm run lint:fix      # Auto-fix style issues
```

**What it checks:**
- Compiler version consistency
- Function visibility declarations
- Unused variables
- Low-level call patterns
- Deprecated functions (suicide, throw, sha3)
- Line length and formatting
- State variable visibility

**Config:** `.solhint.json`

---

### 3. **Hardhat Coverage** - Test Coverage
Measures how much of your code is executed by tests.

**Run Coverage:**
```bash
npm run coverage
```

**Output:**
- Line coverage % for each contract
- Branch coverage (if/else paths tested)
- Function coverage
- Statement coverage
- HTML report in `coverage/index.html`

**Goal:** Aim for >95% coverage on critical contracts (achieved — see [GAS-AND-COVERAGE.md](GAS-AND-COVERAGE.md)).

---

### 4. **Gas Reporter** - Gas Optimization
Tracks gas usage for all contract functions during tests.

**Run with Gas Reporting:**
```bash
npm run test:gas
```

**Output:**
- Gas cost per function call
- Average, min, max gas usage
- USD cost estimates (if COINMARKETCAP_API_KEY is set in .env)
- Saves to `gas-report.txt`

**Use:** Identify expensive operations and optimize before deployment.

---

## Full Security Audit

Run all tools together:

```bash
npm run audit
```

This executes:
1. Solhint (linting)
2. Slither (static analysis)
3. Hardhat Coverage (test coverage)

---

## Interpreting Results

### Slither Severity Levels

- **High (Red):** Critical vulnerabilities that can lead to loss of funds or contract takeover. **Must fix.**
- **Medium (Yellow):** Potential security issues or poor practices. **Should fix.**
- **Low (Green):** Minor issues or optimizations. **Consider fixing.**
- **Informational (Blue):** Best practice suggestions. **Optional.**

### Common False Positives

Slither may report issues that are intentional design choices:

1. **"Contract locking ether"** - If the contract isn't supposed to hold ETH (DAO rejects ETH by design).
2. **"Reentrancy in X"** - If you're using OpenZeppelin's ReentrancyGuard and Checks-Effects-Interactions pattern.
3. **"Low-level call"** - If using `call` for flexible ETH transfers (safer than `transfer`/`send`).
4. **"Timestamp dependence"** - If using `block.timestamp` for non-critical timing (not randomness).

Always review the context before dismissing findings.

---

## Pre-Deployment Checklist

Before deploying to mainnet or production, ensure:

- [ ] All Slither HIGH and MEDIUM issues resolved or documented as false positives
- [ ] Solhint passes with no errors
- [ ] Test coverage >95% on core contracts (currently achieved)
- [ ] Gas costs reviewed and optimized where possible (see [GAS-AND-COVERAGE.md](GAS-AND-COVERAGE.md))
- [ ] Manual code review completed
- [ ] External audit completed (for high-value contracts)
- [ ] Access controls tested (only authorized addresses can call restricted functions)
- [ ] Pause mechanisms tested
- [ ] Upgrade paths tested (if using proxies)
- [ ] Event emissions verified for all state changes

---

## Advanced Testing (Optional)

### Echidna - Fuzzing
Property-based fuzzing to find edge cases.

```bash
# Install (requires Haskell)
docker pull trailofbits/echidna

# Create echidna.yaml config and property contracts
# Run fuzzer
docker run -v $PWD:/src trailofbits/echidna echidna /src/contracts/YourContract.sol
```

### Mythril - Symbolic Execution
Deep analysis using symbolic execution.

```bash
pip3 install mythril
myth analyze contracts/RankedMembershipDAO.sol
```

**Warning:** Mythril is slower but finds different vulnerability classes than Slither.

---

## Getting Help

- **Slither docs:** https://github.com/crytic/slither
- **Solhint rules:** https://github.com/protofire/solhint/blob/master/docs/rules.md
- **Coverage docs:** https://github.com/sc-forks/solidity-coverage
- **Trail of Bits security guide:** https://github.com/crytic/building-secure-contracts

---

## Continuous Integration

Add to GitHub Actions (`.github/workflows/security.yml`):

```yaml
name: Security Audit
on: [push, pull_request]
jobs:
  audit:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v3
      - uses: actions/setup-node@v3
      - run: npm install
      - run: npm run lint
      - run: npm test
      - run: npm run coverage
      # Optionally add Slither
      - uses: crytic/slither-action@v0.3.0
```

---

**Last Updated:** February 12, 2026
