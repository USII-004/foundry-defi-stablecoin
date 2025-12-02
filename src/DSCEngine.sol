// SPDX-License-Identifier: MIT

// This is considered an Exogenous, Decentralized, Anchored (pegged), Crypto Collateralized low volitility coin

// Layout of Contract:
// version
// imports
// interfaces, libraries, contracts
// errors
// Type declarations
// State variables
// Events
// Modifiers
// Functions

// Layout of Functions:
// constructor
// receive function (if exists)
// fallback function (if exists)
// external
// public
// internal
// private
// view & pure functions

pragma solidity ^0.8.19;

import {DecentralizedStableCoin} from "./DecentralizedStableCoin.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {AggregatorV3Interface} from "@chainlink/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol";

/*
 * @title DSCEngine
 * @author Usman Awwal (devUsii)
 *
 * The system is designed to be as minimal as possible, and have the tokens maintain a 1 token == $1 peg.
 * This stablecoin has the properties:
 * - Exogenous Collateral
 * - Dollar Pegged
 * - Algorithmically stable
 *
 * It is similar to DAI if DAI has no governance, no fees, and was only backed by WETH and WBTC
 *
 * Our DSC system should always be "overcollateralized". At no point, should the value of all collateral <= the $ backed value of all the DSC.
 *
 * @notice This contract is the core of the DSC system. It handles all the logic for minting and redeeming DSC, as well as depositing & withdrawing collateral.
 * @notice This contract is VERY loosely based on the MakerDAO DSS (DAI) system 
 */

contract DSCEngine{
  // List out the contract achievables

  /*//////////////////////////////////////////////////////////////
                              ERRORS
  //////////////////////////////////////////////////////////////*/
  error DSCEngine__NeedMoreThanZero();
  error DSCEngine__TokenAddressesAndPriceFeedAddressesMustBeSameLength();
  error DSCEngine__NotAllowedToken();
  error DSCEngine__TransferFailed();
  error DSCEngine__BreaksHealthFactor(uint256 healthFactor);
  error DSCEngine__MintFailed();


  /*//////////////////////////////////////////////////////////////
                              STATE VARIABLES 
  //////////////////////////////////////////////////////////////*/
  uint256 private constant ADDITIONAL_FEED_PRECISION = 1e10;
  uint256 private constant PRECISION = 1e18;
  uint256 private constant LIQUIDATION_THRESHOLD = 50;
  uint256 private constant LIQUIDATION_PRECISION = 100;
  uint256 private constant MIN_HEALTH_FACTOR = 1;

  mapping(address token => address priceFeed) private s_priceFeeds;
  mapping(address user => mapping(address token => uint256 amount)) private s_collateralDeposited;
  mapping(address user => uint256 amountDscMinted) private s_DSCMinted;

  address[] private s_collateralTokens;

  DecentralizedStableCoin private immutable i_dsc;


  /*//////////////////////////////////////////////////////////////
                              EVENTS 
  //////////////////////////////////////////////////////////////*/
  event CollateralDeposited(address indexed user, address indexed token, uint256 indexed amount);


  /*//////////////////////////////////////////////////////////////
                              MODIFIERS 
  //////////////////////////////////////////////////////////////*/
  modifier moreThanZero(uint256 amount) {
    if(amount == 0) {
      revert DSCEngine__NeedMoreThanZero();
    }
    _;
  }

  modifier isAllowedToken(address token) {
    if(s_priceFeeds[token] == address(0)) {
      revert DSCEngine__NotAllowedToken();
    }
    _;
  }


  /*//////////////////////////////////////////////////////////////
                              FUNCTIONS 
  //////////////////////////////////////////////////////////////*/
  constructor(
    address[] memory tokenAddresses,
    address[] memory priceFeedAddresses,
    address dscAddress
  ) {
      if(tokenAddresses.length != priceFeedAddresses.length) {
        revert DSCEngine__TokenAddressesAndPriceFeedAddressesMustBeSameLength();
      }
      for (uint256 i = 0; i < tokenAddresses.length; i++) {
        s_priceFeeds[tokenAddresses[i]] = priceFeedAddresses[i];
        s_collateralTokens.push(tokenAddresses[i]);
      }
      i_dsc = DecentralizedStableCoin(dscAddress);
    }


  /*//////////////////////////////////////////////////////////////
                          EXTERNAL FUNCTIONS 
  //////////////////////////////////////////////////////////////*/
  function depositCollateralAndMintDsc() external {}

  /*
   * @notice follows CEI pattern
   * @param tokenCollateralAddress The address of the token to deposit as collateral
   * @param amountCollateral The amount of collateral to deposit
   */
  function depositCollateral(
    address tokenCollateralAddress,
    uint256 amountCollateral
  )
    external 
    moreThanZero(amountCollateral) 
    isAllowedToken(tokenCollateralAddress)
  {
    s_collateralDeposited[msg.sender][tokenCollateralAddress] += amountCollateral;
    emit CollateralDeposited(msg.sender, tokenCollateralAddress, amountCollateral);

    bool success = IERC20(tokenCollateralAddress).transferFrom(msg.sender, address(this), amountCollateral);
    if(!success) {
      revert DSCEngine__TransferFailed();
    }
  }

  function redeemCollateralforDsc() external {}

  function redeemCollateral() external {}

  // In other to mint DSC, we need to first
  // 1. Check if the collateral value > DSC amount
      // This will involve, price feeds, values etc  
  /*
   * @notice follows CEI
   * @param amountDscToMint The amount of Decentralized Stablecoin to mint
   * @notice they must have more collateral value than the minimum threshold
   */
  function mintDsc(uint256 amountDscToMint) external moreThanZero(amountDscToMint) {
    s_DSCMinted[msg.sender] += amountDscToMint;
    // if they minted too much
    _revertIfHealthFactorIsBroken(msg.sender);
    bool minted = i_dsc.mint(msg.sender, amountDscToMint);
    if(!minted) {
      revert DSCEngine__MintFailed();
    }
  }

  function burnDsc() external {}

  function liquidate() external {}

  function getHealthFactor() external view {}


  /*//////////////////////////////////////////////////////////////
                      PRIVATE & INTERNAL VIEW FUNCTIONS 
  //////////////////////////////////////////////////////////////*/
  function _getAccountInformation(address user) private view returns(uint256 totalDscMinted, uint256 collateralValueInUsd) {
    totalDscMinted = s_DSCMinted[user];
    collateralValueInUsd = getAccountCollateralValue(user);
  }

  /*
   * Returns how close to liquidation a user is
   * If a user goes below 1, then they can get liquidated
   */
  function _healthFactor(address user) private view returns(uint256) {
    // get total DSC minted
    // get total collateral value
    (uint256 totalDscMinted, uint256 collateralValueInUsd) = _getAccountInformation(user);
    uint256 collateralAdjustedForThreshold = (collateralValueInUsd * LIQUIDATION_THRESHOLD) / LIQUIDATION_PRECISION;
    return (collateralAdjustedForThreshold * PRECISION) / totalDscMinted;
  }

  function _revertIfHealthFactorIsBroken(address user) internal view {
    // 1. check health factor (do they have enough collateral)
    // 2. Revert if they don't
    uint256 userHealthFactor = _healthFactor(user);
    if(userHealthFactor < MIN_HEALTH_FACTOR) {
      revert DSCEngine__BreaksHealthFactor(userHealthFactor);
    }

  }


  /*//////////////////////////////////////////////////////////////
                      PUBLIC & EXTERNAL VIEW FUNCTIONS 
  //////////////////////////////////////////////////////////////*/
  function getAccountCollateralValue(address user) public view returns(uint256 totalCollateralValueInUsd) {
    // loop through each collateral token, get the amount they have deposited and map it to price to get the USD value
    for(uint256 i = 0; i < s_collateralTokens.length; i++) {
      address token = s_collateralTokens[i];
      uint256 amount = s_collateralDeposited[user][token];
      totalCollateralValueInUsd += getUsdValue(token, amount);
    }
    return totalCollateralValueInUsd;
  }

  function getUsdValue(address token, uint256 amount) public view returns(uint256) {
    AggregatorV3Interface priceFeed = AggregatorV3Interface(s_priceFeeds[token]);
    (,int256 price,,,) = priceFeed.latestRoundData();
    // 1 ETH = $1000
    // the returned value from CL will be 1000 * 1e8
    return ((uint256(price) * ADDITIONAL_FEED_PRECISION) * amount) / PRECISION;
  }
}