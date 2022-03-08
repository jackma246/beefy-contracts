// SPDX-License-Identifier: GPL-3.0

pragma solidity ^0.6.0;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/SafeERC20.sol";
import "@openzeppelin/contracts/math/SafeMath.sol";

import "../../interfaces/common/IUniswapRouterETH.sol";
import "../../interfaces/common/IUniswapV2Pair.sol";
import "../../interfaces/sushi/IRewarder.sol";
import "../../interfaces/sushi/IMiniChefV2.sol";
import "../Common/StratManager.sol";
import "../Common/FeeManager.sol";


// Commented for my own clarity

// Example use case: 
// Polygon Network
// beefy.finance
// Vault - BCT-USDC SLP

// Strategy:

// 1. Deposit BCT-USDC-SLP, BCT, or USDC. In return, a mooBCT-USDC-SLP token is given to the user as a receipt.
// 2. If deposit wasn't in BCT-USDC-SLP, need to zap the deposit into equal parts, to get the SLP token.
// 3. SLP is the sushi liquidity pool token, the receipt for the liquidity provided. In this case, it's BCT-USDC LP.
// 4. The BCT-USDC-SLP token is then put into the SushiSwap Farm to be staked to earn rewards
// 5. The rewards will compound in the farm and the strategy will continue to harvest whenever it is profitable or when a new deposit enters the vault.
//    New deposits pay for the gas for the harvest based on 
// 6. At any point in time, the user can withdraw from the vault. Since the vault has been autocompounding rewards, the mooBCT-USDC-SLP token will not be 1:1 with the SLP token.
//    They'll get their share of whatever has built up over time.

// Deployed Contract: https://polygonscan.com/address/0x1f9871133c8e093e9e1e2815ca76b75cc7bb8c11#readContract

contract StrategyPolygonSushiLP is StratManager, FeeManager {
    using SafeERC20 for IERC20;
    using SafeMath for uint256;

    // Tokens used

    // Native token on Polygon is MATIC, but since it's not ERC-20 compliant, it is wrapped as WMATIC
    address public native;

    // Output token(s) - SUSHI/MATIC
    address public output;

    // sushiswapLP - USDC/BCT
    address public want;

    // LP token 0 is USDC
    address public lpToken0;

    // LP token 1 is BCT 
    address public lpToken1;

    // Third party contracts

    // Address of MiniChefV2 - SushiSwap Liquidity Mining Contract deployed on Polygon
    address public chef;

    // Pool ID - 50
    uint256 public poolId;

    // timestamp of last harvest - "1646397335" - 3/4/22 4:35 AM
    uint256 public lastHarvest;

    // boolean on whether we harvest upon deposit, in this case it's true - generally it will be true
    bool public harvestOnDeposit;

    // Routes - the path for swapping -> first is input, last is output, and ordered in swap path
    // i.e. [SUSHI, WETH, USDC, BCT] => start with SUSHI, swap to WETH, USDC, output is BCT.

    // SUSHI, WMATIC
    address[] public outputToNativeRoute;

    // WMATIC, SUSHI
    address[] public nativeToOutputRoute;

    // SUSHI, WETH, USDC
    address[] public outputToLp0Route;

    // SUSHI, WETH, USDC, BCT
    address[] public outputToLp1Route;

    // event that harvest was completed and how much was harvested
    event StratHarvest(address indexed harvester, uint256 wantHarvested, uint256 tvl);
    
    // event that deposit was completed successfully to farm and the amount that was deposited
    event Deposit(uint256 tvl);
    
    // event that withdraw was completed from the farm and the amount that was withdrawn
    event Withdraw(uint256 tvl);

    constructor(
        // we want pair of USDC/BCT
        address _want,

        // pool ID in sushi - 50
        uint256 _poolId,

        // address of sushi chef on polygon
        address _chef,

        // address of the beefy vault: https://polygonscan.com/address/0x90a7289a3aab4b070a2646dca757025ee84cf580#code
        // 0x90A7289A3aAb4b070A2646DCa757025Ee84cF580
        // BeefyVaultV6 - mooSushiUSDC-BCT
        address _vault,

        // UniswapV2Router02 - sushiswap router on polygon:
        // 0x1b02dA8Cb0d097eB8D57A175b88c7D8b47997506
        address _unirouter,

        // ???? Unsure - 0x10aee6b5594942433e7fc2783598c979b030ef3d
        // no contract
        address _keeper,

        // StrategistBuyBack - 0x3E85701BA493b6F51d6c301b91b758EC8685fA3c
        // Owner - 0x2C6bd2d42AaA713642ee7c6e83291Ca9F94832C6
        address _strategist,

        // address of the fee receiver
        address _beefyFeeRecipient,

        // SUSHI, WMATIC
        address[] memory _outputToNativeRoute,

        // SUSHI, WETH, USDC
        address[] memory _outputToLp0Route,

        // SUSHI, WETH, USDC, BCT
        address[] memory _outputToLp1Route
    ) public StratManager(_keeper, _strategist, _unirouter, _vault, _beefyFeeRecipient) {
        want = _want;
        poolId = _poolId;
        chef = _chef;

        require(_outputToNativeRoute.length >= 2, "need output to native");
        output = _outputToNativeRoute[0];
        native = _outputToNativeRoute[_outputToNativeRoute.length - 1];
        outputToNativeRoute = _outputToNativeRoute;
        
        // setup lp routing
        lpToken0 = IUniswapV2Pair(want).token0();
        require(_outputToLp0Route[0] == output, "first != output");
        require(_outputToLp0Route[_outputToLp0Route.length - 1] == lpToken0, "last != lptoken0");
        outputToLp0Route = _outputToLp0Route;

        lpToken1 = IUniswapV2Pair(want).token1();
        require(_outputToLp1Route[0] == output, "first != output");
        require(_outputToLp1Route[_outputToLp1Route.length - 1] == lpToken1, "last != lptoken1");
        outputToLp1Route = _outputToLp1Route;

        nativeToOutputRoute = new address[](_outputToNativeRoute.length);
        for (uint i = 0; i < _outputToNativeRoute.length; i++) {
            uint idx = _outputToNativeRoute.length - 1 - i;
            nativeToOutputRoute[i] = outputToNativeRoute[idx];
        }
        // set allowances to max for all possible approvals
        _giveAllowances();
    }

    // deposits full balance of SLP-USDC-BCT into the chef contract and specific pool
    // emits event that the full balance has been deposited
    function deposit() public whenNotPaused {

        // slp token is an erc20, we check the current balance for the strategy
        uint256 wantBal = IERC20(want).balanceOf(address(this));

        // if current balance in the strategy is greater than 0, deposit the full balance into 
        // sushi farm. we gave the approval to chef for the slp token in the constructor
        if (wantBal > 0) {
            // sushi interface deposit into the given pool, the full balance, from this address
            IMiniChefV2(chef).deposit(poolId, wantBal, address(this));
            
            // emits the event of deposit completed
            emit Deposit(balanceOf());
        }
    }

    // withdraw the amount from the farm
    function withdraw(uint256 _amount) external {

        // caller of this function should be the vault
        require(msg.sender == vault, "!vault");

        // check if the strategy has the amount of want in the address non deposited
        uint256 wantBal = IERC20(want).balanceOf(address(this));

        // if not enough balance in strategy, we need to withdraw from the farm
        if (wantBal < _amount) {
            // withdraw from the pool, the amount minus however much strategy is holding at the moment
            IMiniChefV2(chef).withdraw(poolId, _amount.sub(wantBal), address(this));

            // want balance should be equal to the amount requested to withdraw now
            wantBal = IERC20(want).balanceOf(address(this));
        }

        // if strategy holds more than requested
        if (wantBal > _amount) {
            // set the amount to transfer to the vault equal to the amount requested
            wantBal = _amount;
        }

        // if transaction origin is not the owner or the keeper and it's not paused (something controlled by owner)
        if (tx.origin != owner() && !paused()) {
            // take a fee for the withdrawal amount - (default is * 10 /10000)
            uint256 withdrawalFeeAmount = wantBal.mul(withdrawalFee).div(WITHDRAWAL_MAX);
            wantBal = wantBal.sub(withdrawalFeeAmount);
        }

        // transfer to the vault the amount withdrawn
        IERC20(want).safeTransfer(vault, wantBal);

        // emit event for withdrawal
        emit Withdraw(balanceOf());
    }

    // calling before depositing, it should trigger harvest if harvestOnDeposit is set to true
    function beforeDeposit() external override {
        if (harvestOnDeposit) {
            // function caller should  be from the vault (since deposit comes from vault)
            require(msg.sender == vault, "!vault");
            _harvest(tx.origin);
        }
    }

    function harvest() external virtual {
        _harvest(tx.origin);
    }

    function harvest(address callFeeRecipient) external virtual {
        _harvest(callFeeRecipient);
    }

    function managerHarvest() external onlyManager {
        _harvest(tx.origin);
    }

    // compounds earnings and charges performance fee
    function _harvest(address callFeeRecipient) internal whenNotPaused {

        // call sushi farm to harvest the pool -> reward goes to the strategy contract
        IMiniChefV2(chef).harvest(poolId, address(this));
        
        // output balance is the current balance of output (SUSHI token) in strategy
        uint256 outputBal = IERC20(output).balanceOf(address(this));
        
        // if current balance is greater than 0
        if (outputBal > 0) {
            // charge and distribute the harvest fees among the caller, strategist, treasury, and stakers
            chargeFees(callFeeRecipient);

            // add liquidity - what this does is swaps all output token (sushi) into  50% usdc, 50% bct, adds it all to the LP 
            addLiquidity();

            // get the balance of slp token - should be increased after the liquidity adding above
            uint256 wantHarvested = balanceOfWant();

            // deposit full balance of slp token into the farm
            deposit();

            // update last harvest time
            lastHarvest = block.timestamp;

            // emit harvested event
            emit StratHarvest(msg.sender, wantHarvested, balanceOf());
        }
    }

    // performance fees - some fees transferred to beefy recipient, some to strategist, and some to the harvest caller
    function chargeFees(address callFeeRecipient) internal {
        // harvest comes in MATIC and SUSHI both, so swap the MATIC to sushi
        
        // start with getting the balance in MATIC of strategy
        uint256 toOutput = IERC20(native).balanceOf(address(this));

        // if balance of matic is greater than 0, swap all matic into sushi
        if (toOutput > 0) {
            // sushiswap router - swap WMATIC to SUSHI through the native to output route - deadline is now
            IUniswapRouterETH(unirouter).swapExactTokensForTokens(toOutput, 0, nativeToOutputRoute, address(this), now);
        }
        
        // default of 4.5% fees of the harvest are taken 
        // this comes from the output (SUSHI) and we multiply by 45/1000 (.045)

        uint256 toNative = IERC20(output).balanceOf(address(this)).mul(45).div(1000);

        // swapped from SUSHI to WMATIC -> then send the WMATIC to strategy address
        IUniswapRouterETH(unirouter).swapExactTokensForTokens(toNative, 0, outputToNativeRoute, address(this), now);

        // current balance of WMATIC on strategy
        uint256 nativeBal = IERC20(native).balanceOf(address(this));

        // caller of harvest gets their fee in WMATIC
        uint256 callFeeAmount = nativeBal.mul(callFee).div(MAX_FEE);
        IERC20(native).safeTransfer(callFeeRecipient, callFeeAmount);

        // 3% of harvest goes to the treasury, and to the BIFI stakers
        uint256 beefyFeeAmount = nativeBal.mul(beefyFee).div(MAX_FEE);
        IERC20(native).safeTransfer(beefyFeeRecipient, beefyFeeAmount);

        // .5% goes to the strategist of the current strategy
        uint256 strategistFee = nativeBal.mul(STRATEGIST_FEE).div(MAX_FEE);
        IERC20(native).safeTransfer(strategist, strategistFee);
    }

    // Adds liquidity to AMM and gets more LP tokens.
    function addLiquidity() internal {

        // calculates the output (SUSHI) balance on the strategy, and divides it by 2 since we'll split half USDC, half BCT
        uint256 outputHalf = IERC20(output).balanceOf(address(this)).div(2);

        // if the LP is not MATIC (which in this case it's USDC), swap using the route from WMATIC to USDC
        if (lpToken0 != output) {
            IUniswapRouterETH(unirouter).swapExactTokensForTokens(outputHalf, 0, outputToLp0Route, address(this), now);
        }

        // if the LP is not MATIC (which in this case it's BCT), swap using the route from WMATIC to BCT
        if (lpToken1 != output) {
            IUniswapRouterETH(unirouter).swapExactTokensForTokens(outputHalf, 0, outputToLp1Route, address(this), now);
        }

        uint256 lp0Bal = IERC20(lpToken0).balanceOf(address(this));
        uint256 lp1Bal = IERC20(lpToken1).balanceOf(address(this));

        // add liquidity to the USDC/BCT LP - we will receive SLP USDC BCT to this address and deposit all our USDC and BCT balance
        IUniswapRouterETH(unirouter).addLiquidity(lpToken0, lpToken1, lp0Bal, lp1Bal, 1, 1, address(this), now);
    }

    // calculate the total underlying 'want' held by the strat.
    function balanceOf() public view returns (uint256) {
        return balanceOfWant().add(balanceOfPool());
    }

    // it calculates how much 'want' this contract holds.
    function balanceOfWant() public view returns (uint256) {
        return IERC20(want).balanceOf(address(this));
    }

    // it calculates how much 'want' the strategy has working in the farm.
    function balanceOfPool() public view returns (uint256) {
        (uint256 _amount, ) = IMiniChefV2(chef).userInfo(poolId, address(this));	
        return _amount;
    }

    // returns rewards unharvested
    function rewardsAvailable() public view returns (uint256) {
        return IMiniChefV2(chef).pendingSushi(poolId, address(this));
    }

    // native reward amount for calling harvest
    function callReward() public view returns (uint256) {
        uint256 nativeOut;
        address rewarder = IMiniChefV2(chef).rewarder(poolId);
        if (rewarder != address(0)) {
            nativeOut = IRewarder(rewarder).pendingToken(poolId, address(this));
        }

        uint256 outputBal = rewardsAvailable();
        try IUniswapRouterETH(unirouter).getAmountsOut(outputBal, outputToNativeRoute)
                returns (uint256[] memory amountOut)
            {
                nativeOut += amountOut[amountOut.length -1];
            }
            catch {}

        return nativeOut.mul(45).div(1000).mul(callFee).div(MAX_FEE);
    }

    // if harvest on deposit is true, withdraw is free - if it's not true, withdrawal has a fee
    function setHarvestOnDeposit(bool _harvestOnDeposit) external onlyManager {
        harvestOnDeposit = _harvestOnDeposit;

        if (harvestOnDeposit) {
            setWithdrawalFee(0);
        } else {
            setWithdrawalFee(10);
        }
    }

    // called as part of strat migration. Sends all the available funds back to the vault.
    function retireStrat() external {
        require(msg.sender == vault, "!vault");

        IMiniChefV2(chef).emergencyWithdraw(poolId, address(this));

        uint256 wantBal = IERC20(want).balanceOf(address(this));
        IERC20(want).transfer(vault, wantBal);
    }

    // pauses deposits and withdraws all funds from third party systems.
    function panic() public onlyManager {
        pause();
        IMiniChefV2(chef).emergencyWithdraw(poolId, address(this));
    }

    // pauses all actions and removes allowances so no actions can be taken
    function pause() public onlyManager {
        _pause();

        _removeAllowances();
    }

    // unpauses and gives allowances back to sushi chef and router
    function unpause() external onlyManager {
        _unpause();

        _giveAllowances();

        deposit();
    }

    function _giveAllowances() internal {
        IERC20(want).safeApprove(chef, uint256(-1));
        IERC20(output).safeApprove(unirouter, uint256(-1));
        // needed for v2 harvester
        IERC20(native).safeApprove(unirouter, uint256(-1));

        IERC20(lpToken0).safeApprove(unirouter, 0);
        IERC20(lpToken0).safeApprove(unirouter, uint256(-1));

        IERC20(lpToken1).safeApprove(unirouter, 0);
        IERC20(lpToken1).safeApprove(unirouter, uint256(-1));
    }

    function _removeAllowances() internal {
        IERC20(want).safeApprove(chef, 0);
        IERC20(output).safeApprove(unirouter, 0);
        IERC20(native).safeApprove(unirouter, 0);
        IERC20(lpToken0).safeApprove(unirouter, 0);
        IERC20(lpToken1).safeApprove(unirouter, 0);
    }

    function outputToNative() external view returns (address[] memory) {
        return outputToNativeRoute;
    }

    function nativeToOutput() external view returns (address[] memory) {
        return nativeToOutputRoute;
    }

    function outputToLp0() external view returns (address[] memory) {
        return outputToLp0Route;
    }

    function outputToLp1() external view returns (address[] memory) {
        return outputToLp1Route;
    }
}
