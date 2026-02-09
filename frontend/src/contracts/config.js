/*
  Contract addresses — update these after deploying.

  Run `npx hardhat run scripts/deploy.js --network localhost` from the
  project root, then paste the printed addresses below.
*/

const CONTRACTS = {
  // ── Hardhat localhost (chainId 31337) ─────
  31337: {
    dao: "0x5FbDB2315678afecb367f032d93F642f64180aa3",
    governance: "0xe7f1725E7734CE288F8367e1Bb143E90bb3F0512",
    treasury: "0xCf7Ed3AccA5a467e9e704C703E8D87F634fB0Fc9",
    feeRouter: "0xDc64a140Aa3E981100a9becA4E685f962f0cF6C9",
    inviteController: "0x0000000000000000000000000000000000000000",
  },

  // ── Arbitrum Sepolia (chainId 421614) ─────
  421614: {
    dao: "0x0000000000000000000000000000000000000000",
    governance: "0x0000000000000000000000000000000000000000",
    treasury: "0x0000000000000000000000000000000000000000",
    feeRouter: "0x0000000000000000000000000000000000000000",
    inviteController: "0x0000000000000000000000000000000000000000",
  },
};

export function getAddresses(chainId) {
  return CONTRACTS[chainId] ?? null;
}

export default CONTRACTS;
