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
  error DSCEngine__HealthFactorOk();
  error DSCEngine__HealthFactorNotImproved();


  /*//////////////////////////////////////////////////////////////
                              STATE VARIABLES 
  //////////////////////////////////////////////////////////////*/
  uint256 private constant ADDITIONAL_FEED_PRECISION = 1e10;
  uint256 private constant PRECISION = 1e18;
  uint256 private constant LIQUIDATION_THRESHOLD = 50;
  uint256 private constant LIQUIDATION_PRECISION = 100;
  uint256 private constant MIN_HEALTH_FACTOR = 1e18;
  uint256 private constant LIQUIDATION_BONUS = 10;

  mapping(address token => address priceFeed) private s_priceFeeds;
  mapping(address user => mapping(address token => uint256 amount)) private s_collateralDeposited;
  mapping(address user => uint256 amountDscMinted) private s_DSCMinted;

  address[] private s_collateralTokens;

  DecentralizedStableCoin private immutable i_dsc;


  /*//////////////////////////////////////////////////////////////
                              EVENTS 
  //////////////////////////////////////////////////////////////*/
  event CollateralDeposited(address indexed user, address indexed token, uint256 indexed amount);
  event collateralRedeemed(address indexed redeemedFrom, address indexed redeemedTo, address indexed token, uint256 amount);


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

  /*
   * @param tokenCollateralAddress The address of the token to deposit as collateral
   * @param amountCollateral The amount of collateral to deposit
   * @param amountDscToMint The amount of decentralized stable coin to mint
   * @notice this function will deposit collateral and mint DSC in one transaction
   */

  function depositCollateralAndMintDsc(address tokenCollateralAddress, uint256 amountCollateral, uint256 amountDscToMint) external {
    depositCollateral(tokenCollateralAddress, amountCollateral);
    mintDsc(amountDscToMint);
  }

  /*
   * @notice follows CEI pattern
   * @param tokenCollateralAddress The address of the token to deposit as collateral
   * @param amountCollateral The amount of collateral to deposit
   */
  function depositCollateral(
    address tokenCollateralAddress,
    uint256 amountCollateral
  )
    public 
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

  /*
    * @param tokenCollateralAddress the collateral address to redeem
    * @param amountCollateral the amount of collateral to redeem
    * @param amountDscToBurn the amount of decentralized stable coin to burn
    * @notice this functions burns dsc and redeems collateral in one transaction
    */
  function redeemCollateralForDsc(
    address tokenCollateralAddress, 
    uint256 amountCollateral, 
    uint256 amountDscToBurn
    ) 
    external 
    {
    burnDsc(amountDscToBurn);
    redeemCollateral(tokenCollateralAddress, amountCollateral);
    // redeedCollateral already checks health factor
  }

  // In other to redeem collateral
  // 1. health factor must be over 1 after collateral pulled
  function redeemCollateral(address tokenCollateralAddress, uint256 amountCollateral) public moreThanZero(amountCollateral) {
    _redeemCollateral(tokenCollateralAddress, amountCollateral, msg.sender, msg.sender);
    _revertIfHealthFactorIsBroken(msg.sender);
  }

  // In other to mint DSC, we need to first
  // 1. Check if the collateral value > DSC amount
      // This will involve, price feeds, values etc  
  /*
   * @notice follows CEI
   * @param amountDscToMint The amount of Decentralized Stablecoin to mint
   * @notice they must have more collateral value than the minimum threshold
   */
  function mintDsc(uint256 amountDscToMint) public moreThanZero(amountDscToMint) {
    s_DSCMinted[msg.sender] += amountDscToMint;
    // if they minted too much
    _revertIfHealthFactorIsBroken(msg.sender);
    bool minted = i_dsc.mint(msg.sender, amountDscToMint);
    if(!minted) {
      revert DSCEngine__MintFailed();
    }
  }

  function burnDsc(uint256 amount) public moreThanZero(amount) {
    _burnDsc(amount, msg.sender, msg.sender);
    _revertIfHealthFactorIsBroken(msg.sender); // I don't think this would ever hit
  }

  // if we do start nearing undercollateralization, we need someone to liquidate the positions
  // if someone is almost undercollateralized, we will pay you to liquidate them.

  // that is if we have a $75 backing $50 DSC
  // liquidator take $75 backing and burns off the $50 DSC

  /*
    * @param collateral The erc20 collateral address to liquidate from the user
    * @param user The user who has broken the health factor. their _healthFactor should be below MIN_HEALTH_FACTOR
    * @param debtToCover The amount of DSC you want to burn to improve the users health factor
    * @notice You can partially liquidate a user.
    * @notice You will get a liquidation points for taking the users funds
    * @notice This functions working assumes the protocol will be roughly 200% overcollateralized in order for this to work.
    * @notice A known bug will be if the protocol were 100% or less collateralized, then we wouldn't be able to incentivize the liquidators
    */
  function liquidate(address collateral, address user, uint256 debtToCover) external moreThanZero(debtToCover) {
    // check health factor of the user
    uint256 startingUserHealthFactor = _healthFactor(user);
    if(startingUserHealthFactor >= MIN_HEALTH_FACTOR) {
      revert DSCEngine__HealthFactorOk();
    }
    // we want to burn their DSC "debt"
    // And take their collateral
    // Bad user: $140 ETH, $100 DSC
    // debtToCover = $100
    // $100 DSC = ??? ETH?
    uint256 tokenAmountFromDebtCovered = getTokenAmountFromUsd(collateral, debtToCover);
    // And give them a 10% bonus for liquidating someone
    // So we are giving the liquidator $110 of WETH for $100 DSC
    // We should implement a feature to liquidate in the event the protocol is insolvent
    // And sweep extra amount into treasury
    uint256 bonusCollateral = (tokenAmountFromDebtCovered * LIQUIDATION_BONUS) / LIQUIDATION_PRECISION;
    uint256 totalCollateralToRedeem = tokenAmountFromDebtCovered + bonusCollateral;
    _redeemCollateral(collateral, totalCollateralToRedeem, user, msg.sender);
    // we need to burn the DSC
    _burnDsc(debtToCover, user, msg.sender);

    uint256 endingUserHealthFactor = _healthFactor(user);
    if(endingUserHealthFactor <= startingUserHealthFactor) {
      revert DSCEngine__HealthFactorNotImproved();
    }
    _revertIfHealthFactorIsBroken(msg.sender);
  }

  function getHealthFactor() external view {}


  /*//////////////////////////////////////////////////////////////
                      PRIVATE & INTERNAL VIEW FUNCTIONS 
  //////////////////////////////////////////////////////////////*/

  /*
   * @dev Low-level internal function, do not call do not call unless function calling it is checking for health factors being broken 
   */
  function _burnDsc(uint256 amountDscToBurn, address onBehalfOf, address dscFrom) private {
    s_DSCMinted[onBehalfOf] -= amountDscToBurn;
    bool success = i_dsc.transferFrom(dscFrom, address(this), amountDscToBurn);
    // this condition is hypothetically unreachable
    if(!success) {
      revert DSCEngine__TransferFailed();
    }
    i_dsc.burn(amountDscToBurn);
  }

  function _redeemCollateral(address tokenCollateralAddress, uint256 amountCollateral, address from, address to) private {
    s_collateralDeposited[from][tokenCollateralAddress] -= amountCollateral;
    emit collateralRedeemed(from, to, tokenCollateralAddress, amountCollateral);

    bool success = IERC20(tokenCollateralAddress).transfer(to, amountCollateral);
    if(!success) {
      revert DSCEngine__TransferFailed();
    }
  }

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
    return _calculateHealthFactor(totalDscMinted, collateralValueInUsd);
  }

  function _calculateHealthFactor(uint256 totalDscMinted, uint256 collateralValueInUsd) internal pure returns(uint256) {
    if(totalDscMinted == 0) return type(uint256).max;
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
  function calculateHealthFactor(uint256 totalDscMinted, uint256 collateralValueInUsd) external pure returns(uint256) {
    return _calculateHealthFactor(totalDscMinted, collateralValueInUsd);
  }

  function getTokenAmountFromUsd(address token, uint256 usdAmountInWei) public view returns(uint256) {
    // price of ETH (token)
    AggregatorV3Interface priceFeed = AggregatorV3Interface(s_priceFeeds[token]);
    (, int256 price,,,) = priceFeed.latestRoundData();
    return (usdAmountInWei * PRECISION) / (uint256(price) * ADDITIONAL_FEED_PRECISION);
  }

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

  function getAccoutInformation(address user) external view returns(uint256 totalDscMinted, uint256 collateralValueInUsd) {
    (totalDscMinted, collateralValueInUsd) = _getAccountInformation(user);
  }

  function getCollateralBalanceOfUser(address user, address token) external view returns(uint256) {
    return s_collateralDeposited[user][token];
  }

  function getPrecision() external pure returns(uint256) {
    return PRECISION;
  }

  function getAdditionalFeedPrecision() external pure returns(uint256) {
    return ADDITIONAL_FEED_PRECISION;
  }

  function getHealthFactor(address user) external view returns(uint256) {
    return _healthFactor(user);
  }

  function getCollateralTokens() external view returns(address[] memory) {
    return s_collateralTokens;
  }

  function getLiquidationBonus() external pure returns(uint256) {
    return LIQUIDATION_BONUS;
  }

  function getLiquidationPrecision() external pure returns(uint256) {
    return LIQUIDATION_PRECISION;
  }

  function getCollateralTokenPriceFeed(address token) external view returns(address) {
    return s_priceFeeds[token];
  }

  function getMinHealthFactor() external pure returns(uint256) {
    return MIN_HEALTH_FACTOR;
  }

  function getLiquidationThreshold() external pure returns(uint256) {
    return LIQUIDATION_THRESHOLD;
  }

  function getDsc() external view returns(address) {
    return address(i_dsc);
  }
}