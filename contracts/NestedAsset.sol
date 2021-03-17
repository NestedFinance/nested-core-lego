//SPDX-License-Identifier: Unlicense
pragma solidity ^0.7.0;

import "hardhat/console.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import "@openzeppelin/contracts/token/ERC721/ERC721Burnable.sol";
import "@openzeppelin/contracts/utils/Counters.sol";

contract NestedAsset is ERC721, ERC721Burnable, Ownable  {
  event NestedCreated(uint256 indexed tokenId, address indexed owner);

  using Counters for Counters.Counter;
  Counters.Counter private _tokenIds;

  address public factory;

  constructor(address _factory) ERC721("NestedAsset", "NESTED") public {
    factory = _factory;
    console.log("Deploying the Nested Asset Contract: ", address(this));
  }

  function destroy(uint256 _tokenId) public onlyOwner() {
    _burn(_tokenId);
  }

  function mint() public returns (uint256) {
    _tokenIds.increment();

    uint256 newNestedId = _tokenIds.current();
    _safeMint(msg.sender, newNestedId);

    console.log("Owner is: ", owner());
    console.log("TokenId is: ", newNestedId);
    emit NestedCreated(tokenId, owner());

    return newNestedId;
  }
}
