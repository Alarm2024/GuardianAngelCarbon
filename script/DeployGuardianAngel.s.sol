// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import "../src/GuardianAngelCarbon.sol";

contract DeployGuardianAngel is Script {
    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        vm.startBroadcast(deployerPrivateKey);
        
        new GuardianAngelCarbon();
        
        vm.stopBroadcast();
    }
}
