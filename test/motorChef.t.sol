// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import "forge-std/Test.sol";

//import {Comptroller, CToken} from "clm/Comptroller.sol";
//import {WETH} from "clm/WETH.sol";
//
//import {ERC20 as ERC20} from "solmate/tokens/ERC20.sol";

import 'src/motorChef.sol';

contract motorChefTest is Test {

    Comptroller public constant comptroller = Comptroller(0x5E23dC409Fc2F832f83CEc191E245A191a4bCc5C);
    WETH        public constant weth        = WETH(payable(0x826551890Dc65655a0Aceca109aB11AbDbD7a07B));
    address     public constant dep         = 0xF0e4e74Ce34738826477b9280776fc797506fE13;
    address     public constant cNoteCANTO  = 0x3C96dCfd875253A37acB3D2B102b6f328349b16B;
    ERC20       public constant LP          = ERC20(0x42A515C472b3B953beb8ab68aDD27f4bA3792451);
    uint256     public          fork;
    MotorChef   public          chef;

    function setUp() public {
        fork = vm.createSelectFork(vm.envString("RPC_URL"));
        
        vm.startPrank(dep);
            chef = new MotorChef(block.number);
            ERC20(cNoteCANTO).transfer(address(chef), ERC20(cNoteCANTO).balanceOf(dep));
        vm.stopPrank();

        // this is here to do checks that we can run tests in fork enviroment
        assert(weth.balanceOf(address(comptroller)) > 10e18);
        assert(LP.balanceOf(address(dep)) > 1e18);
        assert(ERC20(cNoteCANTO).balanceOf(address(chef)) > 1e18);
    }

    function testStake(uint256 depositAmt) public {
        vm.startPrank(dep);
            LP.approve(address(chef), type(uint256).max);
            
            if(depositAmt <= LP.balanceOf(address(dep))){
                chef.deposit(0, depositAmt);
                assertEq(LP.balanceOf(address(chef)), depositAmt);
            } else {
                vm.expectRevert(bytes("TRANSFER_FROM_FAILED"));
                chef.deposit(0, depositAmt);
            }
        vm.stopPrank();
    }

    function testUnstake() public {
        uint256 initialBal = LP.balanceOf(address(dep));
        
        vm.startPrank(dep);
            LP.approve(address(chef), type(uint256).max);
            chef.deposit(0, 1e18);

            chef.withdraw(0, 1e18);
        vm.stopPrank();

        assertEq(LP.balanceOf(address(chef)), 0);
        assertEq(LP.balanceOf(address(dep)), initialBal);
    }

    function testIndividualDistributions(uint24 rolls) public {
        uint initialWCanto = weth.balanceOf(dep); // check in case the user has WCANTO
        
        vm.startPrank(dep);
            LP.approve(address(chef), type(uint256).max);
            chef.deposit(0, 1e18);

            vm.roll(block.number + rolls);

            uint estimatedAmt = estimatePendingWCANTO(cNoteCANTO, address(chef));
            uint pendingTotalAmt = chef.getPendingWCANTO(CToken(cNoteCANTO));
            uint pendingUserAmt = chef.pendingCanto(0, dep, 0);

            assertEq(pendingTotalAmt, estimatedAmt, "total");
            assert(pendingUserAmt <= estimatedAmt);
            assertApproxEqAbs(pendingUserAmt, estimatedAmt,  1e9, "user");

            chef.deposit(0, 0);
            
            // check how much was actually delivered
            assertApproxEqAbs((weth.balanceOf(dep) - initialWCanto), pendingUserAmt, 1e9, "realized");

        vm.stopPrank();

        assertEq(LP.balanceOf(address(chef)), 1e18);
    }

    function testMultiDistributions() public {
        address alice = address(1);
        address bob = address(2);

        vm.startPrank(dep);
            LP.transfer(alice, 5e18);
            LP.transfer(bob, 10e18);
        vm.stopPrank();
        
        uint initialWCantoAlice = weth.balanceOf(alice); // check in case the user has WCANTO
        uint initialWCantoBob = weth.balanceOf(bob); // check in case the user has WCANTO
        
        vm.startPrank(alice);
            LP.approve(address(chef), type(uint256).max);
            chef.deposit(0, 5e18);

            vm.roll(block.number + 1000);

        vm.stopPrank();

        vm.startPrank(bob);
            LP.approve(address(chef), type(uint256).max);
            chef.deposit(0, 10e18);

            vm.roll(block.number + 3000);
            chef.deposit(0, 0);

        vm.stopPrank();

        vm.startPrank(alice);
            chef.deposit(0, 0);
        vm.stopPrank();

        assertApproxEqAbs((weth.balanceOf(alice) - initialWCantoAlice), (weth.balanceOf(bob) - initialWCantoBob), 1e9, "users unbalanced");

        assertEq(LP.balanceOf(address(chef)), 15e18);
    }


    //////////////////////////////////////////////////////////////////////////////////////////////////////////////////
    //                                                                                                              //
    //                                                  CHECKS                                                      //
    //                                                                                                              //
    //////////////////////////////////////////////////////////////////////////////////////////////////////////////////

    function updateStateIndex(uint224 idx, uint32 lastBlock, address token) internal view returns (uint224) {
        uint256 deltaBlocks = block.number - uint256(lastBlock);
        if(deltaBlocks > 0) {
            uint256 compAccrued = fpMath.mul_(deltaBlocks, comptroller.compSupplySpeeds(token));
            fpMath.Double memory ratio = fpMath.fraction(compAccrued, ERC20(token).totalSupply());
            return uint224(fpMath.add_(fpMath.Double({mantissa: idx}), ratio).mantissa);
        } else {
            return idx;
        }
    }

    function estimatePendingWCANTO(address cToken, address supplier) public view returns (uint256) {
        (uint224 idx, uint32 lastBlock) = comptroller.compSupplyState(cToken);
        idx = updateStateIndex(idx, lastBlock, cToken);
        uint256 supplierIdx = comptroller.compSupplierIndex(cToken, supplier);
        fpMath.Double memory deltaIndex =
            fpMath.Double({mantissa: fpMath.sub_(idx, supplierIdx)});
        uint256 supplierTokens = ERC20(cToken).balanceOf(supplier);
        return fpMath.mul_(supplierTokens, deltaIndex);
    }

}