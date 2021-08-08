// SPDX-License-Identifier: MIT

pragma solidity ^0.6.12;

import "./ERC20.sol";
import "./Address.sol";
import "./SafeERC20.sol";
import "./Ownable.sol";

contract KFI is ERC20("KFI", "KFI"), Ownable {

    using SafeMath for uint256;

    uint256 maxSupply = 100000000e18;

    function mint(address _to, uint256 _amount) public onlyOwner {
        require(_amount.add(this.totalSupply())<=maxSupply,"maxSupply limit");
        _mint(_to, _amount);
    }
}
