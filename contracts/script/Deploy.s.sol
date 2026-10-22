// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {MockStable} from "../src/MockStable.sol";
import {ReceivableNFT} from "../src/ReceivableNFT.sol";
import {CreditVault} from "../src/CreditVault.sol";
import {DefaultEngine} from "../src/DefaultEngine.sol";
import {ArbiterResolver} from "../src/ArbiterResolver.sol";

/// @notice Deploys and wires the full system, then writes the addresses to deployments/<chainid>.json.
///
///   PRIVATE_KEY      required, deployer (becomes owner of every contract)
///   TREASURY         optional, defaults to the deployer
///   SEED_LIQUIDITY   optional, pcUSD (6 decimals) the deployer mints and deposits as the first LP; default 0
///   DEMO_WINDOWS     optional, "true" shortens grace/dispute/auction windows to minutes so the whole
///                    default lifecycle can be shown live. Uses only the normal owner setters.
contract Deploy is Script {
    function run() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(pk);
        address treasury = vm.envOr("TREASURY", deployer);
        uint256 seed = vm.envOr("SEED_LIQUIDITY", uint256(0));
        bool demoWindows = vm.envOr("DEMO_WINDOWS", false);

        vm.startBroadcast(pk);

        MockStable stable = new MockStable(deployer);
        ReceivableNFT nft = new ReceivableNFT(deployer);
        CreditVault vault = new CreditVault(stable, nft, deployer, treasury);
        DefaultEngine engine = new DefaultEngine(vault, nft, stable, deployer);
        ArbiterResolver arbiter = new ArbiterResolver(engine, deployer);

        engine.setResolver(address(arbiter));
        nft.setWiring(address(vault), address(engine));
        vault.setEngine(address(engine));

        if (demoWindows) {
            engine.setGracePeriod(60);
            engine.setDisputeWindow(120);
            engine.setAuctionDuration(180);
            engine.setResolutionTimeout(600);
        }

        if (seed > 0) {
            stable.mint(deployer, seed);
            stable.approve(address(vault), seed);
            vault.deposit(seed, deployer);
        }

        vm.stopBroadcast();

        string memory k = "deployment";
        vm.serializeUint(k, "chainId", block.chainid);
        vm.serializeAddress(k, "deployer", deployer);
        vm.serializeAddress(k, "treasury", treasury);
        vm.serializeAddress(k, "stable", address(stable));
        vm.serializeAddress(k, "receivableNFT", address(nft));
        vm.serializeAddress(k, "vault", address(vault));
        vm.serializeAddress(k, "engine", address(engine));
        string memory json = vm.serializeAddress(k, "arbiter", address(arbiter));
        vm.createDir("deployments", true);
        vm.writeJson(json, string.concat("deployments/", vm.toString(block.chainid), ".json"));

        console2.log("MockStable      ", address(stable));
        console2.log("ReceivableNFT   ", address(nft));
        console2.log("CreditVault     ", address(vault));
        console2.log("DefaultEngine   ", address(engine));
        console2.log("ArbiterResolver ", address(arbiter));
    }
}
