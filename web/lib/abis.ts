import { parseAbi } from "viem";

export const stableAbi = parseAbi([
  "function balanceOf(address) view returns (uint256)",
  "function allowance(address owner, address spender) view returns (uint256)",
  "function approve(address spender, uint256 amount) returns (bool)",
  "function faucet()",
  "function claimed(address) view returns (bool)",
]);

export const nftAbi = parseAbi([
  "function nextId() view returns (uint256)",
  "function ownerOf(uint256) view returns (address)",
  "function locked(uint256) view returns (bool)",
  "function getApproved(uint256) view returns (address)",
  "function receivable(uint256) view returns ((uint128 faceValue, uint64 dueDate, address originator, bytes32 obligor))",
  "function mint(uint128 faceValue, uint64 dueDate, bytes32 obligor, string metadataURI) returns (uint256)",
  "function approve(address to, uint256 tokenId)",
]);

export const vaultAbi = parseAbi([
  "function totalAssets() view returns (uint256)",
  "function totalSupply() view returns (uint256)",
  "function balanceOf(address) view returns (uint256)",
  "function convertToAssets(uint256 shares) view returns (uint256)",
  "function maxWithdraw(address) view returns (uint256)",
  "function sharePrice() view returns (uint256)",
  "function utilizationBps() view returns (uint256)",
  "function outstandingPrincipal() view returns (uint256)",
  "function totalImpairment() view returns (uint256)",
  "function idleCash() view returns (uint256)",
  "function spendableCash() view returns (uint256)",
  "function advanceRateBps() view returns (uint16)",
  "function originationFeeBps() view returns (uint16)",
  "function debtOf(uint256 tokenId) view returns (uint256)",
  "function loans(uint256) view returns (address borrower, bool active, bool seized, uint64 dueDate, uint128 principal, uint128 feeOwed, uint128 impairment)",
  "function deposit(uint256 assets, address receiver) returns (uint256)",
  "function withdraw(uint256 assets, address receiver, address owner) returns (uint256)",
  "function advance(uint256 tokenId) returns (uint256 principal, uint256 fee)",
  "function repay(uint256 tokenId, uint256 amount) returns (uint256 principalPaid, uint256 feePaid)",
]);

export const engineAbi = parseAbi([
  "function statusOf(uint256) view returns (uint8)",
  "function cases(uint256) view returns (uint8 status, bool disputeUsed, uint64 disputeDeadline, uint64 disputedAt, uint64 seizedAt, uint64 liquidatedAt, bytes32 evidence, uint256 bond, uint256 shortfall)",
  "function timeline(uint256) view returns ((uint8 status, uint64 timestamp, bytes32 ref)[])",
  "function currentPrice(uint256) view returns (uint256)",
  "function gracePeriod() view returns (uint64)",
  "function disputeWindow() view returns (uint64)",
  "function auctionDuration() view returns (uint64)",
  "function resolutionTimeout() view returns (uint64)",
  "function recoveryPeriod() view returns (uint64)",
  "function disputeBond() view returns (uint256)",
  "function floorBps() view returns (uint16)",
  "function owner() view returns (address)",
  "function flagOverdue(uint256 tokenId)",
  "function dispute(uint256 tokenId, bytes32 evidence)",
  "function expireDispute(uint256 tokenId)",
  "function seize(uint256 tokenId)",
  "function liquidate(uint256 tokenId, uint256 maxPrice)",
  "function recover(uint256 tokenId, uint256 amount)",
  "function writeOff(uint256 tokenId)",
]);

export const arbiterAbi = parseAbi([
  "function owner() view returns (address)",
  "function resolve(uint256 tokenId, bool upheld, uint64 newDueDate)",
]);
