// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {LendToken} from "./tokenization/LendToken.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/**
 * @title Pool Contract
 * @author Adam
 * @notice This contract manages a lending pool where users can:
 * - Deposit ETH as collateral
 * - Borrow LendTokens against their collateral
 * - Get liquidated if their health factor drops too low
 * @dev Implements a dynamic interest rate model based on pool utilization:
 * - Base rate of 2%
 * - First slope of 4% up to 80% utilization 
 * - Second steeper slope of 75% above 80% utilization
 * - Maintains a 150% collateralization ratio
 * - Uses ReentrancyGuard for security
 */
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
    uint256 public constant LIQUIDATION_THRESHOLD = 150; // 150%
    uint256 public constant BORROW_PRECISION = 100;
    uint256 public constant HEALTH_PRECISION = 1e18;  

    // Interest rate parameters
    uint256 public constant INTEREST_BASE_RATE = 2; // 2%
    uint256 public constant INTEREST_OPTIMAL_UTILIZATION = 80; // 80%
    uint256 public constant INTEREST_SLOPE1 = 4; // 4%
    uint256 public constant INTEREST_SLOPE2 = 75; // 75%
    uint256 public constant INTEREST_PRECISION = 100;

    mapping(address => uint256) public collateralBalance;

    // Event when user deposits collateral
    event CollateralDeposited(address indexed user, uint256 amount);
    // Event when user withdraws collateral
    event CollateralWithdrawn(address indexed user, uint256 amount);
    // Event when user is liquidated
    event CollateralLiquidated(address indexed user, uint256 amountOfCollateral, uint256 amountOfLendTokens);
    // Event when user borrows lend tokens
    event LendTokenBorrowed(address indexed user, uint256 amount);

    /*//////////////////////////////////////////////////////////////
                               FUNCTIONS
    //////////////////////////////////////////////////////////////*/
    /**
     * @notice Constructor for the Pool contract
     * @param _lendToken The address of the LendToken contract
     */
    constructor(address _lendToken) {
        i_lendToken = LendToken(_lendToken);
    }

    /*//////////////////////////////////////////////////////////////
                           EXTERNAL FUNCTIONS
    //////////////////////////////////////////////////////////////*/
    /**
     * @notice Deposit ETH as collateral
     * @param amount The amount of ETH to deposit
     */
    function depositCollateral(uint256 amount) external payable nonReentrant {
        if (msg.value != amount) revert Pool__NotEnoughBalance();
        collateralBalance[msg.sender] += amount;
        emit CollateralDeposited(msg.sender, amount);
    }

    /**
     * @notice Borrow LendTokens against collateral
     * @param amountToBorrow The amount of LendTokens to borrow
     */
    function borrow(uint256 amountToBorrow) external nonReentrant {
        if(collateralBalance[msg.sender] == 0) revert Pool__NotEnoughBalance();
        
        uint256 maxBorrow = (collateralBalance[msg.sender] * BORROW_PRECISION) / COLLATERAL_RATIO;
        if(amountToBorrow > maxBorrow) revert Pool__AmountTooHigh();

        _mintLendToken(amountToBorrow);

        if(healthFactor(msg.sender) < LIQUIDATION_THRESHOLD) {
            revert Pool__HealthFactorTooLow();
        }

        emit LendTokenBorrowed(msg.sender, amountToBorrow);
    }

    /**
     * @notice Calculate the interest rate based on utilization
     * @param utilization The utilization percentage (0-100)
     * @return The interest rate percentage (0-100)
     */
    function calculateInterest(uint256 utilization) public pure returns (uint256) {
        if (utilization <= INTEREST_OPTIMAL_UTILIZATION) {
            return INTEREST_BASE_RATE + (utilization * INTEREST_SLOPE1) / INTEREST_PRECISION;
        } else {
            return INTEREST_BASE_RATE + 
                (INTEREST_OPTIMAL_UTILIZATION * INTEREST_SLOPE1) / INTEREST_PRECISION +
                ((utilization - INTEREST_OPTIMAL_UTILIZATION) * INTEREST_SLOPE2) / INTEREST_PRECISION;
        }
    }

    /**
     * @notice Withdraw collateral
     * @param amount The amount of collateral to withdraw
     */
    function withdrawCollateral(uint256 amount) external nonReentrant {
        if(collateralBalance[msg.sender] < amount) revert Pool__NotEnoughBalance();
        if(i_lendToken.balanceOf(msg.sender) > 0) revert Pool__HasDebt();
        
        collateralBalance[msg.sender] -= amount;
        

        (bool success, ) = msg.sender.call{value: amount}("");
        if (!success) revert Pool__TransferFailed();
        
        emit CollateralWithdrawn(msg.sender, amount);
    }

    /**
     * @notice Calculate the health factor of a user
     * @param user The address of the user
     * @return The health factor (0-100)
     */
    function healthFactor(address user) public view returns (uint256) {
        if (i_lendToken.balanceOf(user) == 0) return type(uint256).max;
        
        return (collateralBalance[user] * HEALTH_PRECISION) / i_lendToken.balanceOf(user);
    }

    /**
     * @notice Liquidate a user's collateral
     * @param user The address of the user
     * @param amount The amount of collateral to liquidate
     */
    function liquidate(address user, uint256 amount) external nonReentrant {
        _liquidate(user, amount);
    }

    /*//////////////////////////////////////////////////////////////
                           INTERNAL FUNCTIONS
    //////////////////////////////////////////////////////////////*/
    /**
     * @notice Mint LendTokens to a user
     * @param amountToMint The amount of LendTokens to mint
     */
    function _mintLendToken(uint256 amountToMint) internal {
        i_lendToken.mint(msg.sender, amountToMint);
    }

    /**
     * @notice Burn LendTokens from a user
     * @param amountOfCollateral The amount of collateral to burn
     * @param user The address of the user
     */
    function _burnLendToken(uint256 amountOfCollateral, address user) internal {
        uint256 lendTokensToBurn = (amountOfCollateral * BORROW_PRECISION) / COLLATERAL_RATIO;
        if(i_lendToken.balanceOf(user) < lendTokensToBurn) revert Pool__NotEnoughBalance();
        i_lendToken.burn(user, lendTokensToBurn);
    }

    /**
     * @notice Liquidate a user's collateral
     * @param user The address of the user
     * @param amount The amount of collateral to liquidate
     */
    function _liquidate(address user, uint256 amount) internal nonReentrant {
        uint256 healthFactorValue = healthFactor(user);
        if(healthFactorValue >= LIQUIDATION_THRESHOLD) {
            revert Pool__HealthFactorIsOk();
        }

        uint256 collateralToLiquidate = amount > collateralBalance[user] ? 
            collateralBalance[user] : amount;
        uint256 tokensToBurn = (collateralToLiquidate * BORROW_PRECISION) / COLLATERAL_RATIO;

        if(tokensToBurn > i_lendToken.balanceOf(user)) {
            revert Pool__NotEnoughTokens();
        }

        collateralBalance[user] -= collateralToLiquidate;
        i_lendToken.burn(user, tokensToBurn);

        emit CollateralLiquidated(user, collateralToLiquidate, tokensToBurn);
    }
    
    receive() external payable {}
}
