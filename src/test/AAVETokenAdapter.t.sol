// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.13;

import {IERC20} from "../../lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";

import {DSTestPlus} from "./utils/DSTestPlus.sol";
import {stdCheats} from "../../lib/forge-std/src/stdlib.sol";

import {
    AAVETokenAdapter,
    InitializationParams as AdapterInitializationParams
} from "../adapters/aave/AAVETokenAdapter.sol";

import {StaticAToken} from "../external/aave/StaticAToken.sol";
import {ILendingPool} from "../interfaces/external/aave/ILendingPool.sol";
import {IAlchemistV2} from "../interfaces/IAlchemistV2.sol";
import {IAlchemistV2AdminActions} from "../interfaces/alchemist/IAlchemistV2AdminActions.sol";
import {IWhitelist} from "../interfaces/IWhitelist.sol";

import {SafeERC20} from "../libraries/SafeERC20.sol";
import {console} from "../../lib/forge-std/src/console.sol";

contract AAVETokenAdapterTest is DSTestPlus, stdCheats {
    uint256 constant BPS = 10000;
    address constant dai = 0x6B175474E89094C44Da98b954EedeAC495271d0F; // ETH mainnet DAI
    ILendingPool lendingPool = ILendingPool(0x7d2768dE32b0b80b7a3454c06BdAc94A69DDc7A9);
    address aToken = 0x028171bCA77440897B824Ca71D1c56caC55b68A3;
    string wrappedTokenName = "staticAaveDai";
    string wrappedTokenSymbol = "saDAI";
    StaticAToken staticAToken;
    AAVETokenAdapter adapter;
    address alchemist = 0x5C6374a2ac4EBC38DeA0Fc1F8716e5Ea1AdD94dd;
    address alchemistAdmin = 0x9e2b6378ee8ad2A4A95Fe481d63CAba8FB0EBBF9;
    address alchemistWhitelist = 0x78537a6CeBa16f412E123a90472C6E0e9A8F1132;

    function setUp() external {
        staticAToken = new StaticAToken(
            lendingPool,
            aToken,
            wrappedTokenName,
            wrappedTokenSymbol
        );
        adapter = new AAVETokenAdapter(AdapterInitializationParams({
            alchemist:       address(this),
            token:           address(staticAToken),
            underlyingToken: address(dai)
        }));
    }

    function testDepositWithdraw() external {
        AAVETokenAdapter newAdapter = new AAVETokenAdapter(AdapterInitializationParams({
            alchemist:       alchemist,
            token:           address(staticAToken),
            underlyingToken: address(dai)
        }));
        IAlchemistV2.YieldTokenConfig memory ytc = IAlchemistV2AdminActions.YieldTokenConfig({
            adapter: address(newAdapter),
            maximumLoss: 1,
            maximumExpectedValue: 1000000 ether,
            creditUnlockBlocks: 7200
        });
        hevm.startPrank(alchemistAdmin);
        IAlchemistV2(alchemist).addYieldToken(address(staticAToken), ytc);
        IAlchemistV2(alchemist).setYieldTokenEnabled(address(staticAToken), true);
        IWhitelist(alchemistWhitelist).add(address(this));
        hevm.stopPrank();

        uint256 amount = 1000 ether;
        tip(dai, address(this), amount);
        uint256 startPrice = IAlchemistV2(alchemist).getUnderlyingTokensPerShare(address(staticAToken));
        IERC20(dai).approve(alchemist, amount);
        IAlchemistV2(alchemist).depositUnderlying(address(staticAToken), amount, address(this), 0);
        (uint256 startShares, ) = IAlchemistV2(alchemist).positions(address(this), address(staticAToken));
        uint256 expectedValue = startShares * startPrice / 1e18;
        assertApproxEq(amount, expectedValue, 1000);

        uint256 startBal = IERC20(dai).balanceOf(address(this));
        assertEq(startBal, 0);

        IAlchemistV2(alchemist).withdrawUnderlying(address(staticAToken), startShares, address(this), 0);
        (uint256 endShares, ) = IAlchemistV2(alchemist).positions(address(this), address(staticAToken));
        assertEq(endShares, 0);

        uint256 endBal = IERC20(dai).balanceOf(address(this));
        assertEq(endBal, amount);
    }

    function testRoundTrip() external {
        tip(dai, address(this), 1e18);

        SafeERC20.safeApprove(dai, address(adapter), 1e18);
        uint256 wrapped = adapter.wrap(1e18, address(this));

        uint256 underlyingValue = wrapped * adapter.price() / 10**SafeERC20.expectDecimals(address(staticAToken));
        assertEq(underlyingValue, 1e18);
        
        SafeERC20.safeApprove(adapter.token(), address(adapter), wrapped);
        uint256 unwrapped = adapter.unwrap(wrapped, address(0xbeef));
        
        assertEq(IERC20(dai).balanceOf(address(0xbeef)), unwrapped);
        assertEq(staticAToken.balanceOf(address(this)), 0);
        assertEq(staticAToken.balanceOf(address(adapter)), 0);
    }

    function testRoundTrip(uint256 amount) external {
        hevm.assume(
            amount >= 10**SafeERC20.expectDecimals(dai) && 
            amount < type(uint96).max
        );
        
        tip(dai, address(this), amount);

        SafeERC20.safeApprove(dai, address(adapter), amount);
        uint256 wrapped = adapter.wrap(amount, address(this));

        uint256 underlyingValue = wrapped * adapter.price() / 10**SafeERC20.expectDecimals(address(staticAToken));
        console.logUint(underlyingValue);
        console.logUint(amount);
        assertGe(underlyingValue, amount - 10); // <10 wei rounding errors
        
        SafeERC20.safeApprove(adapter.token(), address(adapter), wrapped);
        uint256 unwrapped = adapter.unwrap(wrapped, address(0xbeef));
        
        assertEq(IERC20(dai).balanceOf(address(0xbeef)), unwrapped);
        assertEq(staticAToken.balanceOf(address(this)), 0);
        assertEq(staticAToken.balanceOf(address(adapter)), 0);
    }

    function testAppreciation() external {
        tip(dai, address(this), 1e18);

        SafeERC20.safeApprove(dai, address(adapter), 1e18);
        uint256 wrapped = adapter.wrap(1e18, address(this));
        
        hevm.roll(block.number + 1000);
        hevm.warp(block.timestamp + 100000);

        SafeERC20.safeApprove(adapter.token(), address(adapter), wrapped);
        uint256 unwrapped = adapter.unwrap(wrapped, address(0xbeef));
        assertGt(unwrapped, 1e18);
    }
}