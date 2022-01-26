// SPDX-License-Identifier: MIT

pragma solidity ^0.8.10;

import '@openzeppelin/contracts/utils/Address.sol';
import '@openzeppelin/contracts/access/Ownable.sol';
import '@openzeppelin/contracts/token/ERC20/ERC20.sol';
import '@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol';

contract ValleySwapToken is Ownable, ERC20, ERC20Burnable {
  constructor() ERC20("ValleySwap Token", "VS") {}

  function mint(address to, uint amount) public virtual onlyOwner {
      _mint(to, amount);
  }
}
