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

contract DCSEngineTest is Test {
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
}