//SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.7.0;

import "hardhat/console.sol";
import "./NestedAsset.sol";

contract NestedFactory {
    event NestedCreated(uint256 indexed tokenId, address indexed owner);

    address public feeTo;
    address public feeToSetter;

    mapping(address => mapping(address => uint256)) public getUsersTokens;

    constructor(address _feeToSetter) {
        feeToSetter = _feeToSetter;
    }

    function setFeeTo(address _feeTo) external {
        require(msg.sender == feeToSetter, "NestedFactory: FORBIDDEN");
        feeTo = _feeTo;
    }

    function setFeeToSetter(address _feeToSetter) external {
        require(msg.sender == feeToSetter, "NestedFactory: FORBIDDEN");
        feeToSetter = _feeToSetter;
    }
}
