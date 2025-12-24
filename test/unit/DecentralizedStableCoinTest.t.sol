// SPDX-License-Identifier: MIT

pragma solidity ^0.8.19;

import { DecentralizedStableCoin } from "../../src/DecentralizedStableCoin.sol";
import { Test } from "forge-std/Test.sol";
import { StdCheats } from "forge-std/StdCheats.sol";

contract DecentralizedStableCoinTest is Test {
  DecentralizedStableCoin dsc;

  address public USER = makeAddr("user");

  function setUp() public {
    dsc = new DecentralizedStableCoin();  
  }

  /*//////////////////////////////////////////////////////////////
                            MINTTEST
  //////////////////////////////////////////////////////////////*/

  function testNonOwnerCannotMint() public {
    vm.prank(USER);
    vm.expectRevert("Ownable: caller is not the owner");
    dsc.mint(USER, 1e18);
  }

  function testMustMintMoreThanZero() public {
    vm.prank(dsc.owner());
    vm.expectRevert(DecentralizedStableCoin.DecentralizedStableCoin__MustBeMoreThanZero.selector);
    dsc.mint(address(this), 0);
  }

  function testCannotMintToZeroAddress() public {
    vm.startPrank(dsc.owner());
    vm.expectRevert(DecentralizedStableCoin.DecentralizedStableCoin__NotZeroAddress.selector);
    dsc.mint(address(0), 100);
    vm.stopPrank();
  }


  /*//////////////////////////////////////////////////////////////
                            BURNTEST
  //////////////////////////////////////////////////////////////*/

  function testNonOwnerCannotBurn() public {
    vm.prank(USER);
    vm.expectRevert("Ownable: caller is not the owner");
    dsc.burn(1e18);
  }

  function testMustBurnMoreThanZero() public {
    vm.startPrank(dsc.owner());
    dsc.mint(address(this), 100);
    vm.expectRevert(DecentralizedStableCoin.DecentralizedStableCoin__MustBeMoreThanZero.selector);
    dsc.burn(0);
    vm.stopPrank();
  }

  function testCannotBurnMoreThanYouHave() public {
    vm.startPrank(dsc.owner());
    dsc.mint(address(this), 100);
    vm.expectRevert(DecentralizedStableCoin.DecentralizedStableCoin__BurnAmountExceedBalance.selector);
    dsc.burn(150);
    vm.stopPrank();
  }
}