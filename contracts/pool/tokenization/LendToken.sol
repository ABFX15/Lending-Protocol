// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

interface ILendToken is IERC20 {
    function mint(address to, uint256 amount) external;
    function burn(uint256 amount) external;
}

contract LendToken is ERC20, Ownable {
    error InvalidAddress();
    error InvalidAmount();

    constructor() ERC20("LendToken", "LTK") Ownable(msg.sender){}

    function mint(address to, uint256 amount) external onlyOwner {
        if(to == address(0)) revert InvalidAddress();
        if(amount <= 0) revert InvalidAmount();
        _mint(to, amount);
    }

    function burn(address from, uint256 amount) external onlyOwner {
        uint256 balance = balanceOf(from);
        if(balance < amount) revert InvalidAmount();
        _burn(from, amount);
    }
}