// SPDX-License-Identifier: MIT

pragma solidity ^0.8.19;

import {Test} from "forge-std/Test.sol";
import {DeployDSC} from "../../script/DeployDSC.s.sol";
import {HelperConfig} from "../../script/HelperConfig.s.sol";
import {DecentralizedStableCoin} from "../../src/DecentralizedStableCoin.sol";
import {DSCEngine} from "../../src/DSCEngine.sol";
import {ERC20Mock} from "@openzeppelin/contracts/mocks/ERC20Mock.sol";
import { MockV3Aggregator } from "../mocks/MockV3Aggregator.sol";
import { MockFailedTransferFrom } from "../mocks/MockFailedTransferFrom.sol";
import { MockFailedMintDSC } from "../mocks/MockFailedMintDSC.sol";
import { MockFailedTransfer } from "../mocks/MockFailedTransfer.sol";
import { MockMoreDebtDSC } from "../mocks/MockMoreDebtDSC.sol";

contract DCSEngineTest is Test {
  event CollateralRedeemed(address indexed redeemFrom, address indexed redeemTo, address token, uint256 amount);

  DeployDSC deployer;
  DecentralizedStableCoin dsc;
  DSCEngine engine;
  HelperConfig config;
  address ethUsdPriceFeed;
  address btcUsdPriceFeed;
  address weth;
  address wbtc;
  uint256 deployerKey;
  
  uint256 amountToMint = 100 ether;

  address public USER = makeAddr("user");
  uint256 public constant AMOUNT_COLLATERAL = 10 ether;
  uint256 public constant STARTING_USER_BALANCE = 10 ether;
  uint256 public constant MIN_HEALTH_FACTOR = 1e18;
  uint256 public constant LIQUIDATION_THRESHOLD = 50;


  // Liquidation
  address public liquidator = makeAddr("liquidator");
  uint256 public collateralToCover = 20 ether;

  function setUp() public {
    deployer = new DeployDSC();
    (dsc, engine, config) = deployer.run();
    (ethUsdPriceFeed, btcUsdPriceFeed, weth, wbtc, deployerKey) = config.activeNetworkConfig();

    ERC20Mock(weth).mint(USER, STARTING_USER_BALANCE);
    ERC20Mock(wbtc).mint(USER, STARTING_USER_BALANCE);
  }

  /*//////////////////////////////////////////////////////////////
                            CONSTRUCTORTEST
  //////////////////////////////////////////////////////////////*/
  address [] public tokenAddresses;
  address [] public priceFeedAddresses;

  function testIfTokenLengthDoesntMatchPriceFeeds() public {
    tokenAddresses.push(weth);
    priceFeedAddresses.push(ethUsdPriceFeed);
    priceFeedAddresses.push(btcUsdPriceFeed);

    vm.expectRevert(DSCEngine.DSCEngine__TokenAddressesAndPriceFeedAddressesMustBeSameLength.selector);
    new DSCEngine(tokenAddresses, priceFeedAddresses, address(dsc));
  }

  /*//////////////////////////////////////////////////////////////
                            PRICETEST
  //////////////////////////////////////////////////////////////*/

  function testGetUsdValue() public {
    uint256 ethAmount = 15e18;
    uint256 expectedUsd = 30000e18;
    uint256 actualUsd = engine.getUsdValue(weth, ethAmount);
    assertEq(expectedUsd, actualUsd);
  }

  function testGetTokenAmountFromUsd() public {
    uint256 usdAmount = 100 ether;
    uint256 expectedWeth = 0.05 ether;
    uint256 actualWeth = engine.getTokenAmountFromUsd(weth, usdAmount);
    
    assertEq(expectedWeth, actualWeth);
  }


  /*//////////////////////////////////////////////////////////////
                        DEPOSITCOLLATERALTEST
  //////////////////////////////////////////////////////////////*/

  function testRevertIfTransferFromFails() public {
    address owner = msg.sender;
    vm.prank(owner);
    MockFailedTransferFrom mockCollateralToken = new MockFailedTransferFrom();
    tokenAddresses = [address(mockCollateralToken)];
    priceFeedAddresses = [ethUsdPriceFeed];
    // DSC Engine receives the third parameter as dscAddress, Not the tokenAddressused as collateral
    vm.prank(owner);
    DSCEngine mockDsce = new DSCEngine(tokenAddresses, priceFeedAddresses, address(dsc));
    mockCollateralToken.mint(USER, AMOUNT_COLLATERAL);
    vm.startPrank(USER);
    ERC20Mock(address(mockCollateralToken)).approve(address(mockDsce), AMOUNT_COLLATERAL);
    // Act / Assert
    vm.expectRevert(DSCEngine.DSCEngine__TransferFailed.selector);
    mockDsce.depositCollateral(address(mockCollateralToken), AMOUNT_COLLATERAL);
    vm.stopPrank();
  }

  function testRevertIfCollateralZero() public {
    vm.startPrank(USER);
    ERC20Mock(weth).approve(address(engine), AMOUNT_COLLATERAL);

    vm.expectRevert(DSCEngine.DSCEngine__NeedMoreThanZero.selector);
    engine.depositCollateral(weth, 0);
    vm.stopPrank();
  }

  function testRevertWithUnapprovedCollateral() public {
    ERC20Mock ranToken = new ERC20Mock("RAN", "RAN", USER, AMOUNT_COLLATERAL);
    vm.startPrank(USER);

    vm.expectRevert(DSCEngine.DSCEngine__NotAllowedToken.selector);
    engine.depositCollateral(address(ranToken), AMOUNT_COLLATERAL);

    vm.stopPrank();
  }

  modifier depositedCollateral() {
    vm.startPrank(USER);
    ERC20Mock(weth).approve(address(engine), AMOUNT_COLLATERAL);
    engine.depositCollateral(weth, AMOUNT_COLLATERAL);
    vm.stopPrank();
    _;
  }

  function testCanDepositCollateralAndGetAccountInfo() public depositedCollateral {
    (uint256 totalDscMinted, uint256 collateralValueInUsd) = engine.getAccountInformation(USER);

    uint256 expectedTotalDscMinted = 0;
    uint256 expectedDepositAmount = engine.getTokenAmountFromUsd(weth, collateralValueInUsd);
    assertEq(totalDscMinted, expectedTotalDscMinted);
    assertEq(AMOUNT_COLLATERAL, expectedDepositAmount);
  }

  function testCanDepositCollateralWithoutMinting() public depositedCollateral() {
    uint256 userBalance = dsc.balanceOf(USER);
    assertEq(userBalance, 0);
  }


  /*//////////////////////////////////////////////////////////////
                    DEPOSITCOLLATERALANDMINTDSCTEST
  //////////////////////////////////////////////////////////////*/

  function testRevertIfMintedDscBreaksHealthFactor() public {
    (, int256 price,,,) = MockV3Aggregator(ethUsdPriceFeed).latestRoundData();
    amountToMint = (AMOUNT_COLLATERAL * (uint256(price) * engine.getAdditionalFeedPrecision())) / engine.getPrecision();
    vm.startPrank(USER);
    ERC20Mock(weth).approve(address(engine), AMOUNT_COLLATERAL);

    uint256 expectedHealthFactor = engine.calculateHealthFactor(amountToMint, engine.getUsdValue(weth, AMOUNT_COLLATERAL));
    vm.expectRevert(abi.encodeWithSelector(DSCEngine.DSCEngine__BreaksHealthFactor.selector, expectedHealthFactor));
    engine.depositCollateralAndMintDsc(weth, AMOUNT_COLLATERAL, amountToMint);
    vm.stopPrank();
  }

  modifier depositedCollateralAndMintedDsc() {
    vm.startPrank(USER);
    ERC20Mock(weth).approve(address(engine), AMOUNT_COLLATERAL);
    engine.depositCollateralAndMintDsc(weth, AMOUNT_COLLATERAL, amountToMint);
    vm.stopPrank();
    _;
  }

  function testCanMintWithDepositedCollateral() public depositedCollateralAndMintedDsc {
    uint256 userBalance = dsc.balanceOf(USER);
    assertEq(userBalance, amountToMint);
  }

  /*//////////////////////////////////////////////////////////////
                        MINTDSCTEST
  //////////////////////////////////////////////////////////////*/

  //This test needs it's own custum setup
  function testRevertIfMintFails() public {
    // Arrange - setup
    MockFailedMintDSC mockDsc = new MockFailedMintDSC();
    tokenAddresses = [weth];
    priceFeedAddresses = [ethUsdPriceFeed];
    address owner = msg.sender;
    vm.prank(owner);
    DSCEngine mockDsce = new DSCEngine(tokenAddresses, priceFeedAddresses, address(mockDsc));
    mockDsc.transferOwnership(address(mockDsce));
    // Arrange - user
    vm.startPrank(USER);
    ERC20Mock(weth).approve(address(mockDsce), AMOUNT_COLLATERAL);
    vm.stopPrank();
  }

  function testRevertsIfMintAmountIsZero() public {
    vm.startPrank(USER);
    ERC20Mock(weth).approve(address(engine), AMOUNT_COLLATERAL);
    engine.depositCollateralAndMintDsc(weth, AMOUNT_COLLATERAL, amountToMint);
    vm.expectRevert(DSCEngine.DSCEngine__NeedMoreThanZero.selector);
    engine.mintDsc(0);
    vm.stopPrank();
  }

  function testRevertIfMintAmountBreaksHealthFactor() public depositedCollateral {
    (, int256 price,,,) = MockV3Aggregator(ethUsdPriceFeed).latestRoundData();
    amountToMint = (AMOUNT_COLLATERAL * (uint256(price) * engine.getAdditionalFeedPrecision())) / engine.getPrecision();

    vm.startPrank(USER);
    uint256 expectedHealthFactor = engine.calculateHealthFactor(amountToMint, engine.getUsdValue(weth, AMOUNT_COLLATERAL));
    vm.expectRevert(abi.encodeWithSelector(DSCEngine.DSCEngine__BreaksHealthFactor.selector, expectedHealthFactor));
    engine.mintDsc(amountToMint);
    vm.stopPrank();
  }

  function testCanMintDsc() public depositedCollateral {
    vm.prank(USER);
    engine.mintDsc(amountToMint);

    uint256 userBalance = dsc.balanceOf(USER);
    assertEq(userBalance, amountToMint);
  }

  // function testCannotMintWithoutDepositingCollateral() public {
  //   vm.startPrank(USER);
  //   // do not deposit collateral; do not approve anything
  //   // Try to mint - should revert because health factor will be broken
  //   vm.expectRevert(abi.encodeWithSelector(DSCEngine.DSCEngine__BreaksHealthFactor.selector));
  //   engine.mintDsc(amountToMint);
  //   vm.stopPrank();
  // }


  /*//////////////////////////////////////////////////////////////
                        BURNDSCTEST
  //////////////////////////////////////////////////////////////*/
  
  function  testRevertIfBurnAmountIsZero() public {
    vm.startPrank(USER);
    ERC20Mock(weth).approve(address(engine), AMOUNT_COLLATERAL);
    engine.depositCollateralAndMintDsc(weth, AMOUNT_COLLATERAL, amountToMint);
    vm.expectRevert(DSCEngine.DSCEngine__NeedMoreThanZero.selector);
    engine.burnDsc(0);
    vm.stopPrank();
  }

  function testCantBurnMoreThanUserHas() public {
    vm.prank(USER);
    vm.expectRevert();
    engine.burnDsc(1);
  }

  function testCanBurnDsc() public depositedCollateral {
    vm.startPrank(USER);
    engine.mintDsc(amountToMint);
    dsc.approve(address(engine), amountToMint);
    engine.burnDsc(amountToMint);
    vm.stopPrank();

    uint256 userBalance = dsc.balanceOf(USER);
    assertEq(userBalance, 0);
  }


  /*//////////////////////////////////////////////////////////////
                        REDEEMCOLLATERALTEST
  //////////////////////////////////////////////////////////////*/

  // This test needs it's own setup
  function testRevertIfTransferFails() public {
    // Arrange - setup
    address owner = msg.sender;
    vm.prank(owner);
    MockFailedTransfer mockDsc = new MockFailedTransfer();
    tokenAddresses = [address(mockDsc)];
    priceFeedAddresses = [ethUsdPriceFeed];
    vm.prank(owner);
    DSCEngine mockDsce = new DSCEngine(tokenAddresses, priceFeedAddresses, address(mockDsc));
    mockDsc.mint(USER, AMOUNT_COLLATERAL);

    vm.prank(owner);
    mockDsc.transferOwnership(address(mockDsce));
    // Arrange - user
    vm.startPrank(USER);
    ERC20Mock(address(mockDsc)).approve(address(mockDsce), AMOUNT_COLLATERAL);
    // Act / Assert
    mockDsce.depositCollateral(address(mockDsc), AMOUNT_COLLATERAL);
    vm.expectRevert(DSCEngine.DSCEngine__TransferFailed.selector);
    mockDsce.redeemCollateral(address(mockDsc), AMOUNT_COLLATERAL);
    vm.stopPrank();
  }

  function testRevertIfRedeemAmountIsZero() public {
    vm.startPrank(USER);
    ERC20Mock(weth).approve(address(engine), AMOUNT_COLLATERAL);
    engine.depositCollateralAndMintDsc(weth, AMOUNT_COLLATERAL, amountToMint);
    vm.expectRevert(DSCEngine.DSCEngine__NeedMoreThanZero.selector);
    engine.redeemCollateral(weth, 0);
    vm.stopPrank();
  }

  function testCanRedeemCollateral() public depositedCollateral {
    vm.startPrank(USER);
    uint256 userBalanceBeforeRedeem = engine.getCollateralBalanceOfUser(USER, weth);
    assertEq(userBalanceBeforeRedeem, AMOUNT_COLLATERAL);
    engine.redeemCollateral(weth, AMOUNT_COLLATERAL);
    uint256 userBalanceAfterRedeem = engine.getCollateralBalanceOfUser(USER, weth);
    assertEq(userBalanceAfterRedeem, 0);
    vm.stopPrank();
  }

  // function testEmitCollateralRedeemedWithCorrectArgs() public depositedCollateral {
  //   vm.startPrank(USER);

  //   vm.expectEmit(true, true, true, true, address(engine));
  //   emit CollateralRedeemed(USER, USER, weth, AMOUNT_COLLATERAL);
    
  //   engine.redeemCollateral(weth, AMOUNT_COLLATERAL);
  //   vm.stopPrank();
  // }


  /*//////////////////////////////////////////////////////////////
                      REDEEMCOLLATERALFORDSCTEST
  //////////////////////////////////////////////////////////////*/

  function testMustRedeemMoreThanZero() public depositedCollateralAndMintedDsc {
    vm.startPrank(USER);
    dsc.approve(address(engine), amountToMint);
    vm.expectRevert(DSCEngine.DSCEngine__NeedMoreThanZero.selector);
    engine.redeemCollateralForDsc(weth, 0, amountToMint);
    vm.stopPrank();
  }

  function testCanRedeemDepositedCollateral() public {
    vm.startPrank(USER);
    ERC20Mock(weth).approve(address(engine), AMOUNT_COLLATERAL);
    engine.depositCollateralAndMintDsc(weth, AMOUNT_COLLATERAL, amountToMint);
    dsc.approve(address(engine), amountToMint);
    engine.redeemCollateralForDsc(weth, AMOUNT_COLLATERAL, amountToMint);
    vm.stopPrank();

    uint256 userBalance = dsc.balanceOf(USER);
    assertEq(userBalance, 0);
  }


  /*//////////////////////////////////////////////////////////////
                      HEALTHFACTORTEST
  //////////////////////////////////////////////////////////////*/

  function testProperlyReportHealthFactor() public depositedCollateralAndMintedDsc {
    uint256 expectedHealthFactor = 100 ether;
    uint256 healthFactor = engine.getHealthFactor(USER);
    // $100 minted with $20,000 collateral at 50% liquidation threshold
    // means that we must have $200 collateral at all times.
    // $20,000 * 0.5 = $10,000
    // 10,000 / 100 = 100 health factor
    assertEq(expectedHealthFactor, healthFactor); 
  }

  function testHealthFactorCannotGoBelowOne() public depositedCollateralAndMintedDsc {
    int256 ethUsdUpdatedPrice = 18e8; // 1 ETH = $18
    // Remember, we need $200 at all times if we have $100 of debt

    MockV3Aggregator(ethUsdPriceFeed).updateAnswer(ethUsdUpdatedPrice);

    uint256 userHealthFactor = engine.getHealthFactor(USER);
    // 180*50 (LIQUIDATION_THRESHOLD) / 100 (LIQUIDATION_PRECISION) / 100 (PRECISION) = 90 / 100 (totalDscMinted) =
    // 0.9
    assert(userHealthFactor == 0.9 ether);   
  }

  /*//////////////////////////////////////////////////////////////
                      LIQUIDATIONTEST
  //////////////////////////////////////////////////////////////*/

  // This function needs it's own setup
  function testMustImproveHealthFactorOnLiquidation() public {
    // Arrange - Setup
    MockMoreDebtDSC mockDsc = new MockMoreDebtDSC(ethUsdPriceFeed);
    tokenAddresses = [weth];
    priceFeedAddresses = [ethUsdPriceFeed];
    address owner = msg.sender;
    vm.prank(owner);
    DSCEngine mockDsce = new DSCEngine(tokenAddresses, priceFeedAddresses, address(mockDsc));
    mockDsc.transferOwnership(address(mockDsce));
    // Arrange - User
    vm.startPrank(USER);
    ERC20Mock(weth).approve(address(mockDsce), AMOUNT_COLLATERAL);
    mockDsce.depositCollateralAndMintDsc(weth, AMOUNT_COLLATERAL, amountToMint);
    vm.stopPrank();

    // Arrange - Liquidator
    collateralToCover = 1 ether;
    ERC20Mock(weth).mint(liquidator, collateralToCover);

    vm.startPrank(liquidator);
    ERC20Mock(weth).approve(address(mockDsce), collateralToCover);
    uint256 debtToCover = 10 ether;
    mockDsce.depositCollateralAndMintDsc(weth, collateralToCover, amountToMint);
    mockDsc.approve(address(mockDsce), debtToCover);
    // Act
    int256 ethUsdUpdatedPrice = 18e8; // 1 ETH = $18
    MockV3Aggregator(ethUsdPriceFeed).updateAnswer(ethUsdUpdatedPrice);
    // Act/Assert
    vm.expectRevert(DSCEngine.DSCEngine__HealthFactorNotImproved.selector);
    mockDsce.liquidate(weth, USER, debtToCover);
    vm.stopPrank();
  }

  function testCanLiquidateGoodHealthFactor() public depositedCollateralAndMintedDsc {
    ERC20Mock(weth).mint(liquidator, collateralToCover);

    vm.startPrank(liquidator);
    ERC20Mock(weth).approve(address(engine), collateralToCover);
    engine.depositCollateralAndMintDsc(weth, collateralToCover, amountToMint);
    dsc.approve(address(engine), amountToMint);

    vm.expectRevert(DSCEngine.DSCEngine__HealthFactorOk.selector);
    engine.liquidate(weth, USER, amountToMint);
    vm.stopPrank();
  }

  modifier liquidated() {
    vm.startPrank(USER);
    ERC20Mock(weth).approve(address(engine), AMOUNT_COLLATERAL);
    engine.depositCollateralAndMintDsc(weth, AMOUNT_COLLATERAL, amountToMint);
    vm.stopPrank();
    int256 ethUsdUpdatedPrice = 18e8;

    MockV3Aggregator(ethUsdPriceFeed).updateAnswer(ethUsdUpdatedPrice);
    uint256 userHealthFactor = engine.getHealthFactor(USER);

    ERC20Mock(weth).mint(liquidator, collateralToCover);

    vm.startPrank(liquidator);
    ERC20Mock(weth).approve(address(engine), collateralToCover);
    engine.depositCollateralAndMintDsc(weth, collateralToCover, amountToMint);
    dsc.approve(address(engine), amountToMint);
    engine.liquidate(weth, USER, amountToMint);
    vm.stopPrank();
    _;
  }

  function testLiquidationPayoutIsCorrect() public liquidated {
    uint256 liquidatorWethBalance = ERC20Mock(weth).balanceOf(liquidator);
    uint256 expectedWeth = engine.getTokenAmountFromUsd(weth, amountToMint) 
      + (engine.getTokenAmountFromUsd(weth, amountToMint) * engine.getLiquidationBonus() / engine.getLiquidationPrecision());
    uint256 hardCodedExpected = 6_111_111_111_111_111_110;
    assertEq(liquidatorWethBalance, hardCodedExpected);
    assertEq(liquidatorWethBalance, expectedWeth);
  }

  function testUserStillHasSomeEthAfterLiquidating() public liquidated {
    // Get how much weth the USER lost
    uint256 amountLiquidated = engine.getTokenAmountFromUsd(weth, amountToMint) 
      + (engine.getTokenAmountFromUsd(weth, amountToMint) * engine.getLiquidationBonus() / engine.getLiquidationPrecision());

    uint256 usdAmountLiquidated = engine.getUsdValue(weth, amountLiquidated);
    uint256 expectedUserCollateralValueInUsd = engine.getUsdValue(weth, AMOUNT_COLLATERAL) - (usdAmountLiquidated);

    (, uint256 userCollateralValueInUsd) = engine.getAccountInformation(USER);
    uint256 hardCodedExpectedValue = 70_000_000_000_000_000_020;
    assertEq(userCollateralValueInUsd, expectedUserCollateralValueInUsd);
    assertEq(userCollateralValueInUsd, hardCodedExpectedValue);
  }

  function testLiquidatorTakesOnUserDebt() public liquidated {
    (uint256 liquidatorDscMinted,) = engine.getAccountInformation(liquidator);
    assertEq(liquidatorDscMinted, amountToMint);
  }

  function testUserHasNoMoreDebt() public liquidated {
    (uint256 userDscMinted,) = engine.getAccountInformation(USER);
    assertEq(userDscMinted, 0);
  }


  /*//////////////////////////////////////////////////////////////
                      VIEWANDPUREFUNCTIONSTEST
  //////////////////////////////////////////////////////////////*/

  function testGetCollateralTokenPriceFeed() public {
    address priceFeed = engine.getCollateralTokenPriceFeed(weth);
    assertEq(priceFeed, ethUsdPriceFeed);
  }

  function testGetCollatralTokens() public {
    address[] memory collateralTokens = engine.getCollateralTokens();
    assertEq(collateralTokens[0], weth);
  }

  function testGetMinHealthFactor() public {
    uint256 minHealthFactor = engine.getMinHealthFactor();
    assertEq(minHealthFactor, MIN_HEALTH_FACTOR);
  }

  function testGetLiquidationThreshold() public {
    uint256 liquidationThreshold = engine.getLiquidationThreshold();
    assertEq(liquidationThreshold, LIQUIDATION_THRESHOLD);
  }

  function testGetAccountCollateralValueFromInformation() public depositedCollateral {
    (, uint256 collateralValue) = engine.getAccountInformation(USER);
    uint256 expectedCollateralValue = engine.getUsdValue(weth, AMOUNT_COLLATERAL);
    assertEq(collateralValue, expectedCollateralValue); 
  }

  function testCollateralBalanceOfUser() public {
    vm.startPrank(USER);
    ERC20Mock(weth).approve(address(engine), AMOUNT_COLLATERAL);
    engine.depositCollateral(weth, AMOUNT_COLLATERAL);
    vm.stopPrank();
    uint256 collateralBalance = engine.getCollateralBalanceOfUser(USER, weth);
    assertEq(collateralBalance, AMOUNT_COLLATERAL);
  }

  function testGetAccountCollateralValue() public {
    vm.startPrank(USER);
    ERC20Mock(weth).approve(address(engine), AMOUNT_COLLATERAL);
    engine.depositCollateral(weth, AMOUNT_COLLATERAL);
    vm.stopPrank();
    uint256 collateralValue = engine.getAccountCollateralValue(USER);
    uint256 expectedCollateralValue = engine.getUsdValue(weth, AMOUNT_COLLATERAL);
    assertEq(collateralValue, expectedCollateralValue);
  }

  function testGetDsc() public {
    address dscAddress = engine.getDsc();
    assertEq(dscAddress, address(dsc));
  }

  function testLiquidationPrecision() public {
    uint256 expectedLiquidationPrecision = 100;
    uint256 actualLiquidationPrecision = engine.getLiquidationPrecision();
    assertEq(expectedLiquidationPrecision, actualLiquidationPrecision);
  }
}