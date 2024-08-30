// SPDX-License-Identifier: MIT
pragma solidity 0.8.7;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract MockToken is ERC20 {
    constructor(
        string memory name,
        string memory symbol,
        uint256 prec
    ) public ERC20(name, symbol) {
        uint256 amount = 10000000000 * prec;
        _mint(msg.sender, amount);
        ERC20.transfer(msg.sender, amount);
    }

    function mint(uint256 amount) public {
        _mint(msg.sender, amount);
        ERC20.transfer(msg.sender, amount);
    }
}
