//SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.3;

import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import "./libraries/NestedStructs.sol";
import "./NestedAsset.sol";
import "./NestedReserve.sol";
import "./NestedRecords.sol";
import "./interfaces/IWETH.sol";
import "./interfaces/IFeeSplitter.sol";
import "./libraries/ExchangeHelpers.sol";

// import "hardhat/console.sol";

contract NestedFactory is ReentrancyGuard {
    using SafeERC20 for IERC20;
    event NestedCreated(uint256 indexed tokenId, address indexed owner);
    event UnexpectedWithdraw(uint256 indexed tokenId, address indexed token);

    uint256 constant MAX_HOLDINGS_COUNT = 15;

    IWETH public immutable weth;
    IFeeSplitter public feeTo;
    address public feeToSetter;

    NestedReserve public reserve;
    NestedAsset public immutable nestedAsset;
    NestedRecords private immutable nestedRecords;

    /*
    Reverts if the address does not exist
    @param _address [address]
    */
    modifier addressExists(address _address) {
        require(_address != address(0), "NestedFactory: INVALID_ADDRESS");
        _;
    }

    /*
    @param _asset [NestedReserve]
    @param _feeToSetter [address] The address which will be allowed to choose where the fees go
    @param _feeTo [IFeeSplitter] the address or contract that receives fees
    @param _weth [IWETH] The wrapped ether contract
    */
    constructor(
        NestedAsset _asset,
        NestedRecords _records,
        address _feeToSetter,
        IFeeSplitter _feeTo,
        IWETH _weth
    ) {
        feeToSetter = _feeToSetter;
        feeTo = _feeTo;
        weth = _weth;
        nestedAsset = _asset;
        nestedRecords = _records;
    }

    /*
    Reverts the transaction if the caller is not the token owner
    @param tokenId uint256 the NFT Id
    */
    modifier onlyTokenOwner(uint256 tokenId) {
        require(nestedAsset.ownerOf(tokenId) == msg.sender, "NestedFactory: NOT_TOKEN_OWNER");
        _;
    }

    /*
    Receive function 
    */
    receive() external payable {}

    /*
   Sets the address receiving the fees
   @param feeTo The address of the receiver
   */
    function setFeeTo(IFeeSplitter _feeTo) external addressExists(address(_feeTo)) {
        require(msg.sender == feeToSetter, "NestedFactory: FORBIDDEN");
        feeTo = _feeTo;
    }

    /*
    Sets the address that can redirect the fees to a new receiver
    @param _feeToSetter The address that decides where the fees go
    */
    function setFeeToSetter(address payable _feeToSetter) external addressExists(_feeToSetter) {
        require(msg.sender == feeToSetter, "NestedFactory: FORBIDDEN");
        feeToSetter = _feeToSetter;
    }

    /*
    Sets the reserve where the funds are stored
    @param _reserve the address of the new factory
    */
    function setReserve(NestedReserve _reserve) external {
        require(address(_reserve) != address(0), "NestedFactory: INVALID_ADDRESS");
        require(address(reserve) == address(0), "NestedFactory: FACTORY_IMMUTABLE");
        reserve = _reserve;
    }

    /*
    Returns the list of NestedAsset ids owned by an address
    @params account [address] address
    @return [<uint256>]
    */
    function tokensOf(address _address) public view virtual returns (uint256[] memory) {
        uint256 tokensCount = nestedAsset.balanceOf(_address);
        uint256[] memory tokenIds = new uint256[](tokensCount);

        for (uint256 i = 0; i < tokensCount; i++) {
            tokenIds[i] = nestedAsset.tokenOfOwnerByIndex(_address, i);
        }
        return tokenIds;
    }

    /*
    Returns the holdings associated to a NestedAsset
    @params _tokenId [uint256] the id of the NestedAsset
    @return [<Holding>]
    */
    function tokenHoldings(uint256 _tokenId) public view virtual returns (NestedStructs.Holding[] memory) {
        address[] memory tokens = nestedRecords.getAssetTokens(_tokenId);
        uint256 tokensCount = tokens.length;
        NestedStructs.Holding[] memory holdings = new NestedStructs.Holding[](tokensCount);

        for (uint256 i = 0; i < tokensCount; i++) {
            NestedStructs.Holding memory holding = nestedRecords.getAssetHolding(_tokenId, tokens[i]);
            holdings[i] = holding;
        }
        return holdings;
    }

    /*
    Purchase tokens and store them in a reserve for the user.
    @param _tokenId [uint] the id of the Nested NFT
    @param _sellToken [IERC20] token used to make swaps
    @param _swapTarget [address] the address of the contract that will swap tokens
    @param _tokenOrders [<TokenOrder>] orders for token swaps
    @param _maxAllowance [<uint256>] maximum allowance needed to perform a swap
    */
    function exchangeAndStoreTokens(
        uint256 _tokenId,
        IERC20 _sellToken,
        address payable _swapTarget,
        NestedStructs.TokenOrder[] calldata _tokenOrders
    ) internal {
        uint256 buyCount = _tokenOrders.length;

        for (uint256 i = 0; i < buyCount; i++) {
            uint256 balanceBeforePurchase = IERC20(_tokenOrders[i].token).balanceOf(address(this));
            bool success = ExchangeHelpers.fillQuote(_sellToken, _swapTarget, _tokenOrders[i].callData);
            require(success, "SWAP_CALL_FAILED");
            uint256 amountBought = IERC20(_tokenOrders[i].token).balanceOf(address(this)) - balanceBeforePurchase;

            nestedRecords.store(_tokenId, _tokenOrders[i].token, amountBought, address(reserve));
            IERC20(_tokenOrders[i].token).safeTransfer(address(reserve), amountBought);
        }
    }

    /*
    Purchase tokens and store them in a reserve for the user.
    @param _originalTokenId [uint] the id of the NFT replicated, 0 if not replicating
    @param _metadataURI The metadata URI string
    @param _sellToken [IERC20] token used to make swaps
    @param _sellTokenAmount [uint] amount of sell tokens to exchange
    @param _swapTarget [address] the address of the contract that will swap tokens
    @param _tokenOrders [<TokenOrder>] orders for token swaps
    */
    function create(
        uint256 _originalTokenId,
        string memory _metadataURI,
        IERC20 _sellToken,
        uint256 _sellTokenAmount,
        address payable _swapTarget,
        NestedStructs.TokenOrder[] calldata _tokenOrders
    ) external payable nonReentrant {
        require(_tokenOrders.length > 0, "BUY_ARG_MISSING");
        require(_tokenOrders.length <= MAX_HOLDINGS_COUNT, "TOO_MANY_ORDERS");

        uint256 fees = _sellTokenAmount / 100;
        uint256 sellAmountWithFees = _sellTokenAmount + fees;

        uint256 tokenId = nestedAsset.mint(msg.sender, _metadataURI, _originalTokenId);

        // pays with ETH
        if (address(_sellToken) == 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE) {
            require(msg.value >= sellAmountWithFees, "INSUFFICIENT_AMOUNT_IN");
            weth.deposit{ value: msg.value }();
            _sellToken = IERC20(address(weth));
        } else {
            // pays with an ERC20
            _sellToken.safeTransferFrom(msg.sender, address(this), sellAmountWithFees);
        }
        uint256 balanceBeforePurchase = IERC20(_sellToken).balanceOf(address(this));
        exchangeAndStoreTokens(tokenId, _sellToken, _swapTarget, _tokenOrders);
        uint256 amountSpent = balanceBeforePurchase - IERC20(_sellToken).balanceOf(address(this));
        require(amountSpent <= _sellTokenAmount, "OVERSPENT_ERROR");
        transferFee(_sellTokenAmount - amountSpent + fees, _sellToken, tokenId);
    }

    /*
    burn NFT and return tokens to the user.
    @param _tokenId uint256 NFT token Id
    */
    function destroy(uint256 _tokenId) external onlyTokenOwner(_tokenId) {
        address[] memory tokens = nestedRecords.getAssetTokens(_tokenId);

        // get assets list for this NFT and send back all ERC20 to user
        for (uint256 i = 0; i < tokens.length; i++) _withdraw(_tokenId, tokens[i]);

        // burn token
        nestedRecords.removeNFT(_tokenId);
        nestedAsset.burn(msg.sender, _tokenId);
    }

    /*
    send a holding content back to the owner without exchanging it
    @param _tokenId [uint256] NFT token ID
    @param _token [address] token address for the holding.
    */
    function _withdraw(uint256 _tokenId, address _token) internal onlyTokenOwner(_tokenId) {
        uint256 assetTokensLength = nestedRecords.getAssetTokensLength(_tokenId);

        require(assetTokensLength > 1, "ERR_SHOULD_DESTROY_ENTIRE_NFT");
        require(_token != address(0), "INVALID_TOKEN_INDEX");

        NestedStructs.Holding memory holding = nestedRecords.getAssetHolding(_tokenId, _token);
        // TODO: add fee
        reserve.transfer(msg.sender, IERC20(holding.token), holding.amount);
        nestedRecords.removeHolding(_tokenId, _token);
    }

    /*
    send a holding content back to the owner without exchanging it
    @param _tokenId [uint256] NFT token ID
    @param _tokenIndex [uint256] index in array of tokens for this NFT and holding.
    @param _token [address] token address for the holding. Used to make sure previous index param is valid
    */
    function withdraw(
        uint256 _tokenId,
        uint256 _tokenIndex,
        address _token
    ) external onlyTokenOwner(_tokenId) {
        require(nestedRecords.assetTokens(_tokenId, _tokenIndex) == _token, "INVALID_TOKEN_INDEX");

        _withdraw(_tokenId, _token);
        nestedRecords.removeToken(_tokenId, _tokenIndex);
        nestedRecords.removeHolding(_tokenId, _token);
    }

    /*
    Burn NFT and Sell all tokens for a specific ERC20
    @param  _tokenId uint256 NFT token Id
    @param _buyToken [IERC20] token used to make swaps
    @param _swapTarget [address] the address of the contract that will swap tokens
    @param _tokenOrders [<TokenOrder>] orders for token swaps
    */
    function _destroyForERC20(
        uint256 _tokenId,
        IERC20 _buyToken,
        address payable _swapTarget,
        NestedStructs.TokenOrder[] calldata _tokenOrders
    ) internal onlyTokenOwner(_tokenId) returns (uint256) {
        address[] memory tokens = nestedRecords.getAssetTokens(_tokenId);
        uint256 tokenLength = tokens.length;

        require(tokenLength == _tokenOrders.length, "MISSING_SELL_ARGS");

        uint256 buyTokenInitialBalance = _buyToken.balanceOf(address(this));

        // first transfer holdings from reserve to factory
        for (uint256 i = 0; i < tokenLength; i++) {
            NestedStructs.Holding memory holding = nestedRecords.getAssetHolding(_tokenId, tokens[i]);
            NestedReserve(holding.reserve).transfer(address(this), IERC20(holding.token), holding.amount);
            bool success =
                ExchangeHelpers.fillQuote(IERC20(_tokenOrders[i].token), _swapTarget, _tokenOrders[i].callData);
            if (success) nestedRecords.removeHolding(_tokenId, tokens[i]);
            else {
                _withdraw(_tokenId, holding.token);
                emit UnexpectedWithdraw(_tokenId, holding.token);
            }
        }

        // send swapped ERC20 to user minus fees
        uint256 amountBought = _buyToken.balanceOf(address(this)) - buyTokenInitialBalance;
        uint256 amountFees = amountBought / 100;
        amountBought = amountBought - amountFees;

        transferFee(amountFees, _buyToken, _tokenId);

        nestedRecords.removeNFT(_tokenId);
        nestedAsset.burn(msg.sender, _tokenId);

        return amountBought;
    }

    /*
    Burn NFT and Sell all tokens for a specific ERC20 then send it back to the user
    @param  _tokenId uint256 NFT token Id
    @param _buyToken [IERC20] token used to make swaps
    @param _swapTarget [address] the address of the contract that will swap tokens
    @param _tokenOrders [<TokenOrder>] orders for token swaps
    */
    function destroyForERC20(
        uint256 _tokenId,
        IERC20 _buyToken,
        address payable _swapTarget,
        NestedStructs.TokenOrder[] calldata _tokenOrders
    ) external onlyTokenOwner(_tokenId) {
        uint256 amountBought = _destroyForERC20(_tokenId, _buyToken, _swapTarget, _tokenOrders);
        require(IERC20(_buyToken).transfer(msg.sender, amountBought), "TOKEN_TRANSFER_ERROR");
    }

    /*
    Burn NFT and Sell all tokens for WETH, unwrap it and then send ETH back to the user
    @param  _tokenId uint256 NFT token Id
    @param _swapTarget [address] the address of the contract that will swap tokens
    @param _tokenOrders [<TokenOrder>] orders for token swaps
    */
    function destroyForETH(
        uint256 _tokenId,
        address payable _swapTarget,
        NestedStructs.TokenOrder[] calldata _tokenOrders
    ) external payable onlyTokenOwner(_tokenId) {
        // no need to check for reeentrancy because destroyForERC20 checks it
        uint256 amountBought = _destroyForERC20(_tokenId, IERC20(address(weth)), _swapTarget, _tokenOrders);
        IWETH(weth).withdraw(amountBought);

        (bool success, ) = msg.sender.call{ value: amountBought }("");
        require(success, "ETH_TRANSFER_ERROR");
    }

    /**
    @dev send a fee to the FeeSplitter
    @param _amount [uint256] to send
    @param _token [IERC20] token to send
    @param _tokenId [uint256] user portfolio ID used to find a potential royalties recipient
    */
    function transferFee(
        uint256 _amount,
        IERC20 _token,
        uint256 _tokenId
    ) internal {
        address originalOwner = nestedAsset.originalOwner(_tokenId);
        ExchangeHelpers.setMaxAllowance(_token, address(feeTo));
        feeTo.sendFeesToken(originalOwner, _amount, _token);
    }
}
