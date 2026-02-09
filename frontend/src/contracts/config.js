/*
  Contract addresses — update these after deploying.

  Run `npx hardhat run scripts/deploy.js --network localhost` from the
  project root, then paste the printed addresses below.
*/

const CONTRACTS = {
  // ── Hardhat localhost (chainId 31337) ─────
  31337: {
    dao: "0x0000000000000000000000000000000000000000",
    governance: "0x0000000000000000000000000000000000000000",
    treasury: "0x0000000000000000000000000000000000000000",
    feeRouter: "0x0000000000000000000000000000000000000000",
  },

  // ── Arbitrum Sepolia (chainId 421614) ─────
  421614: {
    dao: "0x0000000000000000000000000000000000000000",
    governance: "0x0000000000000000000000000000000000000000",
    treasury: "0x0000000000000000000000000000000000000000",
    feeRouter: "0x0000000000000000000000000000000000000000",
  },
};

export function getAddresses(chainId) {
  return CONTRACTS[chainId] ?? null;
}

export default CONTRACTS;
