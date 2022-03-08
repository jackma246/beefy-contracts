// SPDX-License-Identifier: GPL-3.0

pragma solidity ^0.6.0;

import "@openzeppelin/contracts/token/ERC20/SafeERC20.sol";
import "@openzeppelin/contracts/math/SafeMath.sol";

import "../../interfaces/omnidex/IOmnidexRouter01.sol";
import "../../interfaces/omnidex/IOmnidexPair.sol";
import "../../interfaces/omnidex/IZenMaster.sol";
import "../Common/StratManager.sol";
import "../Common/FeeManager.sol";


// Example use case: 
// Telos Network
// Vault - omni-USDT-USDC-LP

// Strategy:

// 1. Deposit USDT-USDC-LP. In return, a moo-USDT-USDC-LP token is given to the user as a receipt.
// 2. The USDT-USDC-LP token is then put into the OmniDex Farm to be staked to earn rewards
// 3. The rewards will compound in the farm and the strategy will continue to harvest whenever it is profitable or when a new deposit enters the vault.
// 4. When harvested, the earned CHARM will be sold for equal parts USDC and USDT. 4.5% fees are taken, and the rest are reinvested into the LP. 
//    The resulting LP tokens are staked into the farm.
// 5. At any point in time, the user can withdraw from the vault. Since the vault has been autocompounding rewards, the mooBCT-USDC-SLP token will not be 1:1 with the SLP token.
//    They'll get their share of whatever has built up over time.

// Deployed Contract of Strategy: 

contract StrategyTelosOmnidexLP is StratManager, FeeManager {
    using SafeERC20 for IERC20;
    using SafeMath for uint256;

    // Tokens used

    // Native token on Telos is TLOS, wrapped version is WTLOS
    // 0xD102cE6A4dB07D247fcc28F366A623Df0938CA9E
    address public native;

    // Output token(s) - CHARM token
    // 0xd2504a02fABd7E546e41aD39597c377cA8B0E1Df
    address public output;

    // OmniDexLP - USDT/USDC LP
    // 0x8805F519663E47aBd6adbA4303639f69e51fd112
    address public want;

    // LP token 0 is USDT
    // 0xefaeee334f0fd1712f9a8cc375f427d9cdd40d73
    address public lpToken0;
    
    // LP token 1 is USDC
    // 0x818ec0a7fe18ff94269904fced6ae3dae6d6dc0b
    address public lpToken1;

    // Third party contracts

    // Address of OmniDex - Liquidity Mining Contract deployed on TLOS
    // 0x79f5A8BD0d6a00A41EA62cdA426CEf0115117a61
    // It's called ZenMaster
    address public chef;

    // Pool ID - ??
    uint256 public poolId;

    // timestamp of last harvest - "1646397335" - 3/4/22 4:35 AM
    uint256 public lastHarvest;

    // boolean on whether we harvest upon deposit, in this case it's true - generally it will be true
    bool public harvestOnDeposit;

    // Routes - the path for swapping -> first is input, last is output, and ordered in swap path
    // i.e. [SUSHI, WETH, USDC, BCT] => start with SUSHI, swap to WETH, USDC, output is BCT.

    // CHARM, WTLOS
    // [0xd2504a02fABd7E546e41aD39597c377cA8B0E1Df, 0xD102cE6A4dB07D247fcc28F366A623Df0938CA9E]
    address[] public outputToNativeRoute;

    // WTLOS, CHARM
    // [0xD102cE6A4dB07D247fcc28F366A623Df0938CA9E, 0xd2504a02fABd7E546e41aD39597c377cA8B0E1Df]
    address[] public nativeToOutputRoute;

    // CHARM, USDC, USDT
    // [0xd2504a02fABd7E546e41aD39597c377cA8B0E1Df, 0x818ec0a7fe18ff94269904fced6ae3dae6d6dc0b, 0xefaeee334f0fd1712f9a8cc375f427d9cdd40d73]
    address[] public outputToLp0Route;

    // CHARM, USDC
    // [0xd2504a02fABd7E546e41aD39597c377cA8B0E1Df, 0x818ec0a7fe18ff94269904fced6ae3dae6d6dc0b]
    address[] public outputToLp1Route;

    // event that harvest was completed and how much was harvested
    event StratHarvest(address indexed harvester, uint256 wantHarvested, uint256 tvl);
    
    // event that deposit was completed successfully to farm and the amount that was deposited
    event Deposit(uint256 tvl);
    
    // event that withdraw was completed from the farm and the amount that was withdrawn
    event Withdraw(uint256 tvl);

    constructor(
        // we want pair of USDT/USDC
        address _want,

        // pool ID in omnidex = 10
        uint256 _poolId,

        // address of zenmaster on telos
        address _chef,

        // address of the beefy vault: we need to deploy this
        // BeefyVaultV6 - mooOmniUSDT-USDC
        address _vault,

        // UniswapV2Router02 - omnidex router on telos:
        // 0xF9678db1CE83f6f51E5df348E2Cc842Ca51EfEc1
        address _unirouter,

        // can just be an owner address if we are not using chainlink keepers
        address _keeper,

        // StrategistBuyBack -  
        // Owner - same, just an address to collect fees
        address _strategist,

        // address of the fee receiver - BIFI pool
        address _beefyFeeRecipient,

        // CHARM, WTLOS
        // [0xd2504a02fABd7E546e41aD39597c377cA8B0E1Df, 0xD102cE6A4dB07D247fcc28F366A623Df0938CA9E]
        address[] memory _outputToNativeRoute,

        // CHARM, USDC, USDT
        // [0xd2504a02fABd7E546e41aD39597c377cA8B0E1Df, 0x818ec0a7fe18ff94269904fced6ae3dae6d6dc0b, 0xefaeee334f0fd1712f9a8cc375f427d9cdd40d73]
        address[] memory _outputToLp0Route,

        // CHARM, USDC
        // [0xd2504a02fABd7E546e41aD39597c377cA8B0E1Df, 0x818ec0a7fe18ff94269904fced6ae3dae6d6dc0b]
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
        lpToken0 = IOmnidexPair(want).token0();
        require(_outputToLp0Route[0] == output, "first != output");
        require(_outputToLp0Route[_outputToLp0Route.length - 1] == lpToken0, "last != lptoken0");
        outputToLp0Route = _outputToLp0Route;

        lpToken1 = IOmnidexPair(want).token1();
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

    // deposits full balance of LP-USDT-USDC into the zenmaster contract and specific pool
    // emits event that the full balance has been deposited
    function deposit() public whenNotPaused {

        // lp token is an erc20, we check the current balance for the strategy
        uint256 wantBal = IOmnidexERC20(want).balanceOf(address(this));
z
        // if current balance in the strategy is greater than 0, deposit the full balance into 
        // omnidex farm. we gave the approval to chef for the slp token in the constructor
        if (wantBal > 0) {
            // omnidex interface deposit into the given pool, the full balance
            IZenMaster(chef).deposit(poolId, wantBal);
            
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
            IZenMaster(chef).withdraw(poolId, _amount.sub(wantBal));

            // set want balance to balance in strategy
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

        // call farm to harvest the pool -> reward goes to the strategy contract -> harvest in omnidex is in deposit, so we deposit 0
        IZenMaster(chef).deposit(poolId, 0);
        
        // output balance is the current balance of output (SUSHI token) in strategy
        uint256 outputBal = IERC20(output).balanceOf(address(this));
        
        // if current balance is greater than 0
        if (outputBal > 0) {
            // charge and distribute the harvest fees among the caller, strategist, treasury, and stakers
            chargeFees(callFeeRecipient);

            // add liquidity - what this does is swaps all output token (sushi) into  50% usdt, 50% usdc, adds it all to the LP 
            addLiquidity();

            // get the balance of slp token - should be increased after the liquidity adding above
            uint256 wantHarvested = balanceOfWant();

            // deposit full balance of lp token into the farm
            deposit();

            // update last harvest time
            lastHarvest = block.timestamp;

            // emit harvested event
            emit StratHarvest(msg.sender, wantHarvested, balanceOf());
        }
    }

    // performance fees - some fees transferred to beefy recipient, some to strategist, and some to the harvest caller
    function chargeFees(address callFeeRecipient) internal {

        // All rewards come in CHARM

        // default of 4.5% fees of the harvest are taken 
        // this comes from the CHARM that we swap into WTLOS and we multiply by 45/1000 (.045)

        uint256 toNative = IERC20(output).balanceOf(address(this)).mul(45).div(1000);

        // swap from CHARM to WTLOS -> then send the WTLOS to strategy address
        IOmnidexRouter02(unirouter).swapExactTokensForTokens(toNative, 0, outputToNativeRoute, address(this), now);

        // current balance of WTLOS on strategy
        uint256 nativeBal = IERC20(native).balanceOf(address(this));

        // caller of harvest gets their fee in WTLOS
        uint256 callFeeAmount = nativeBal.mul(callFeze).div(MAX_FEE);
        IERC20(native).zsafeTransfer(callFeeRecipient, callFeeAmount);

        // 3% of harvest goes to the treasury, and to the BIFI stakers
        uint256 beefyFeeAmount = nativeBal.mul(beefyFee).div(MAX_FEE);
        IERC20(native).safeTransfer(beefyFeeRecipient, beefyFeeAmount);

        // .5% goes to the strategist of the current strategy
        uint256 strategistFee = nativeBal.mul(STRATEGIST_FEE).div(MAX_FEE);
        IERC20(native).safeTransfer(strategist, strategistFee);
    }

    // Adds liquidity to AMM and gets more LP tokens.
    function addLiquidity() internal {

        // calculates the output (CHARM) balance on the strategy, and divides it by 2 since we'll split half USDC, half BCT
        uint256 outputHalf = IERC20(output).balanceOf(address(this)).div(2);

        // if the LP is not WTLOS (which in this case it's USDT), swap using the route from WTLOS to USDT
        if (lpToken0 != output) {
            IOmnidexRouter02(unirouter).swapExactTokensForTokens(outputHalf, 0, outputToLp0Route, address(this), now);
        }

        // if the LP is not WTLOS (which in this case it's USDC), swap using the route from WTLOS to USDC
        if (lpToken1 != output) {
            IOmnidexRouter02(unirouter).swapExactTokensForTokens(outputHalf, 0, outputToLp1Route, address(this), now);
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
        (uint256 _amount, ) = IZenMaster(chef).userInfo(poolId, address(this));	
        return _amount;
    }

    // returns rewards unharvested
    function rewardsAvailable() public view returns (uint256) {
        return IZenMaster(chef).pendingCharm(poolId, address(this));
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

        IZenMaster(chef).emergencyWithdraw(poolId);

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
    }z
}
