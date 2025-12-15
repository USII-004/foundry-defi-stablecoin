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
    (uint256 totalDscMinted, uint256 collateralValueInUsd) = engine.getAccoutInformation(USER);

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
}