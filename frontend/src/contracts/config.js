/*
  Contract addresses — update these after deploying.

  Run `npx hardhat run scripts/deploy.js --network localhost` from the
  project root, then paste the printed addresses below.
*/

const CONTRACTS = {
  // ── Hardhat localhost (chainId 31337) ─────
  31337: {
    dao: "0x7a2088a1bFc9d81c55368AE168C2C02570cB814F",
    orderController: "0xc5a5C42992dECbae36851359345FE25997F5C42d",
    proposalController: "0x67d269191c92Caf3cD7723F116c85e6E9bf55933",
    treasury: "0xc3e53F4d16Ae77Db1c982e75a937B9f60FE63690",
    feeRouter: "0x84eA74d481Ee0A5332c457a4d796187F6Ba67fEB",
    inviteController: "0x9E545E3C0baAB3E08CdfD552C960A1050f373042",
  },

  // ── Arbitrum Sepolia (chainId 421614) ─────
  421614: {
    dao: "0x0000000000000000000000000000000000000000",
    orderController: "0x0000000000000000000000000000000000000000",
    proposalController: "0x0000000000000000000000000000000000000000",
    treasury: "0x0000000000000000000000000000000000000000",
    feeRouter: "0x0000000000000000000000000000000000000000",
    inviteController: "0x0000000000000000000000000000000000000000",
  },
};

export function getAddresses(chainId) {
  return CONTRACTS[chainId] ?? null;
}

export default CONTRACTS;
