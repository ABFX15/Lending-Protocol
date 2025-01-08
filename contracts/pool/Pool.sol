// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {LendToken} from "./tokenization/LendToken.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {AggregatorV3Interface} from "@chainlink/contracts/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";

contract Pool is ReentrancyGuard {
    /*//////////////////////////////////////////////////////////////
                                 ERRORS
    //////////////////////////////////////////////////////////////*/
    error Pool__NotEnoughBalance();
    error Pool__HealthFactorIsOk(); 
    error Pool__HasDebt();
    error Pool__NotEnoughTokens();  
    error Pool__AmountTooHigh();
    error Pool__HealthFactorTooLow();
    error Pool__TransferFailed();

    /*//////////////////////////////////////////////////////////////
                                 STATE
    //////////////////////////////////////////////////////////////*/
    LendToken public immutable i_lendToken;

    uint256 public constant COLLATERAL_RATIO = 150; // 150%
    uint256 public constant PRECISION = 100;
    uint256 public constant BASE_RATE = 2; // 2%
    uint256 public constant OPTIMAL_UTILIZATION = 80; // 80%
    uint256 public constant SLOPE1 = 4; // 80%
    uint256 public constant SLOPE2 = 75; // 80%


    mapping(address => uint256) public collateralBalance;

    event CollateralDeposited(address indexed user, uint256 amount);
    event CollateralWithdrawn(address indexed user, uint256 amount);
    event CollateralLiquidated(address indexed user, uint256 amountOfCollateral, uint256 amountOfLendTokens);
    event LendTokenBorrowed(address indexed user, uint256 amount);

    /*//////////////////////////////////////////////////////////////
                               FUNCTIONS
    //////////////////////////////////////////////////////////////*/
    constructor(address _lendToken) {
        i_lendToken = LendToken(_lendToken);
    }

    /*//////////////////////////////////////////////////////////////
                           EXTERNAL FUNCTIONS
    //////////////////////////////////////////////////////////////*/
    function depositCollateral(uint256 amount) external payable nonReentrant {
        if (msg.value != amount) revert Pool__NotEnoughBalance();
        collateralBalance[msg.sender] += amount;
        emit CollateralDeposited(msg.sender, amount);
    }

    function borrow(uint256 amountToBorrow) external nonReentrant {
        if(collateralBalance[msg.sender] == 0) revert Pool__NotEnoughBalance();
        
        uint256 maxBorrow = (collateralBalance[msg.sender] * PRECISION) / COLLATERAL_RATIO;
        if(amountToBorrow > maxBorrow) revert Pool__AmountTooHigh();

        // Check health factor before minting
        if(healthFactor(msg.sender) < COLLATERAL_RATIO) {
            revert Pool__HealthFactorTooLow();
        }

        _mintLendToken(amountToBorrow);
        emit LendTokenBorrowed(msg.sender, amountToBorrow);
    }

    function calculateInterest(uint256 utilization) public pure returns (uint256) {
        if (utilization <= OPTIMAL_UTILIZATION) {
            return BASE_RATE + (utilization * SLOPE1) / PRECISION;
        } else {
            return BASE_RATE + SLOPE1 * OPTIMAL_UTILIZATION / PRECISION +
                ((utilization - OPTIMAL_UTILIZATION) * SLOPE2) / PRECISION;
        }
    }

    function withdrawCollateral(uint256 amount) external nonReentrant {
        if(collateralBalance[msg.sender] < amount) revert Pool__NotEnoughBalance();
        if(i_lendToken.balanceOf(msg.sender) > 0) revert Pool__HasDebt();
        
        collateralBalance[msg.sender] -= amount;
        

        (bool success, ) = msg.sender.call{value: amount}("");
        if (!success) revert Pool__TransferFailed();
        
        emit CollateralWithdrawn(msg.sender, amount);
    }

    function healthFactor(address user) public view returns (uint256) {
        // If user hasn't borrowed anything, return max uint256
        if (i_lendToken.balanceOf(user) == 0) return type(uint256).max;
        
        // should be >= COLLATERAL_RATIO (150%)
        return (collateralBalance[user] * PRECISION) / i_lendToken.balanceOf(user);
    }

    function liquidate(address user, uint256 amount) external nonReentrant {
        _liquidate(user, amount);
    }

    /*//////////////////////////////////////////////////////////////
                           INTERNAL FUNCTIONS
    //////////////////////////////////////////////////////////////*/
    function _mintLendToken(uint256 amountToMint) internal {
        i_lendToken.mint(msg.sender, amountToMint);
    }

    function _burnLendToken(uint256 amountOfCollateral, address user) internal {
        uint256 lendTokensToBurn = (amountOfCollateral * PRECISION) / COLLATERAL_RATIO;
        if(i_lendToken.balanceOf(user) < lendTokensToBurn) revert Pool__NotEnoughBalance();
        i_lendToken.burn(user, lendTokensToBurn);
    }

    function _liquidate(address user, uint256 amount) internal nonReentrant {
        uint256 healthFactorValue = healthFactor(user);
        if(healthFactorValue >= COLLATERAL_RATIO) {
            revert Pool__HealthFactorIsOk();
        }

        uint256 collateralToLiquidate = amount > collateralBalance[user] ? 
            collateralBalance[user] : amount;
        uint256 tokensToBurn = (collateralToLiquidate * PRECISION) / COLLATERAL_RATIO;

        if(tokensToBurn > i_lendToken.balanceOf(user)) {
            revert Pool__NotEnoughTokens();
        }

        collateralBalance[user] -= collateralToLiquidate;
        i_lendToken.burn(user, tokensToBurn);

        emit CollateralLiquidated(user, collateralToLiquidate, tokensToBurn);
    }
    
    receive() external payable {}
}
