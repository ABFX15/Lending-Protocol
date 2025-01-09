// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {LendToken} from "./tokenization/LendToken.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {AggregatorV3Interface} from "@chainlink/contracts/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";

/**
 * @title Pool Contract
 * @author Adam
 * @notice This contract manages a lending pool where users can:
 * - Deposit ETH as collateral
 * - Borrow LendTokens against their collateral (150% collateral ratio)
 * - Get liquidated if their health factor drops below 1
 * @dev Implements:
 * - Dynamic interest rate model based on utilization:
 *   - Base rate: 2%
 *   - First slope: 4% up to 80% utilization
 *   - Second slope: 75% above 80% utilization
 * - Health factor calculation using price feeds
 * - Liquidation threshold at 50% of collateral value
 * - ReentrancyGuard for security
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
    AggregatorV3Interface public immutable i_ethUsdPriceFeed;

    uint256 private constant COLLATERAL_RATIO = 150; // 150%
    uint256 private constant LIQUIDATION_THRESHOLD = 50; 
    uint256 private constant BORROW_PRECISION = 100;
    uint256 private constant PRICE_FEED_DECIMALS = 1e8;
    uint256 private constant LIQUIDATION_PRECISION = 100;
    uint256 private constant MIN_HEALTH_FACTOR = 1e18;
    uint256 private constant PRECISION = 1e18;

    // Interest rate parameters
    uint256 private constant INTEREST_BASE_RATE = 2; // 2%
    uint256 private constant INTEREST_OPTIMAL_UTILIZATION = 80; // 80%
    uint256 private constant INTEREST_SLOPE1 = 4; // 4%
    uint256 private constant INTEREST_SLOPE2 = 75; // 75%
    uint256 private constant INTEREST_PRECISION = 100;

    // Mapping to store collateral balance of users
    mapping(address => uint256) public collateralBalance;

    // Event when user deposits collateral
    event CollateralDeposited(address indexed user, uint256 amount);
    // Event when user withdraws collateral
    event CollateralWithdrawn(address indexed user, uint256 amount);
    // Event when user is liquidated
    event CollateralLiquidated(address indexed user, uint256 amountOfCollateral, uint256 amountOfLendTokens);
    // Event when user borrows lend tokens
    event LendTokenBorrowed(address indexed user, uint256 amount);

    // Total supply and borrowed amount
    uint256 public totalSupply;
    uint256 public totalBorrowed;

    /*//////////////////////////////////////////////////////////////
                               FUNCTIONS
    //////////////////////////////////////////////////////////////*/
    /**
     * @notice Constructor for the Pool contract
     * @param _lendToken The address of the LendToken contract
     * @param _ethUsdPriceFeed The address of the ETH/USD price feed
     */
    constructor(
        address _lendToken, 
        address _ethUsdPriceFeed,
        uint256 _totalSupply, 
        uint256 _totalBorrowed
    ) {
        i_lendToken = LendToken(_lendToken);
        i_ethUsdPriceFeed = AggregatorV3Interface(_ethUsdPriceFeed);
        totalSupply = _totalSupply;
        totalBorrowed = _totalBorrowed;
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
        totalSupply += amount;
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

        totalBorrowed += amountToBorrow;
        _mintLendToken(amountToBorrow);
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
        totalSupply -= amount;

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
        
        // Get total collateral value in USD
        uint256 collateralValueInUsd = (collateralBalance[user] * getEthUsdPrice()) / PRICE_FEED_DECIMALS;
        uint256 totalDscMinted = i_lendToken.balanceOf(user);
        
        return _calculateHealthFactor(totalDscMinted, collateralValueInUsd);
    }

    /**
     * @notice Liquidate a user's collateral
     * @param user The address of the user
     * @param amount The amount of collateral to liquidate
     */
    function liquidate(address user, uint256 amount) external nonReentrant {
        _liquidate(user, amount);
    }

    function transferLendTokenOwnership(address newOwner) external {
        i_lendToken.transferOwnership(newOwner);
    }

    /*//////////////////////////////////////////////////////////////
                           INTERNAL FUNCTIONS
    //////////////////////////////////////////////////////////////*/
    function _calculateHealthFactor(uint256 totalDscMinted, uint256 collateralValueInUsd) internal pure returns (uint256) {
        if (totalDscMinted == 0) return type(uint256).max;
        
        // Reorder operations to multiply before dividing
        return (collateralValueInUsd * LIQUIDATION_THRESHOLD * PRECISION) / (LIQUIDATION_PRECISION * totalDscMinted);
    }
    
    /**
     * @notice Mint LendTokens to a user
     * @param amountToMint The amount of LendTokens to mint
     */
    function _mintLendToken(uint256 amountToMint) internal {
        i_lendToken.mint(msg.sender, amountToMint);
    }

    /**
     * @notice Liquidate a user's collateral
     * @param user The address of the user
     * @param amount The amount of collateral to liquidate
     */
    function _liquidate(address user, uint256 amount) internal {
        uint256 userHealthFactor = healthFactor(user);
        if(userHealthFactor >= MIN_HEALTH_FACTOR) {
            revert Pool__HealthFactorIsOk();
        }

        uint256 tokensToBurn = (amount * BORROW_PRECISION) / COLLATERAL_RATIO;
        collateralBalance[user] -= amount;
        i_lendToken.burn(user, tokensToBurn);

        emit CollateralLiquidated(user, amount, tokensToBurn);
    }
    
    receive() external payable {}

    fallback() external payable {}

    /*//////////////////////////////////////////////////////////////
                               UTILITY FUNCTIONS
    //////////////////////////////////////////////////////////////*/
    /**
     * @notice Get the ETH/USD price
     * @return The ETH/USD price
     */
    function getEthUsdPrice() public view returns (uint256) {
        (
            /* uint80 roundId */,
            int256 price,
            /* uint256 startedAt */,
            /* uint256 updatedAt */,
            /* uint80 answeredInRound */
        ) = i_ethUsdPriceFeed.latestRoundData();
        return uint256(price);
    }

    // Add this function for testing
    function setCollateralBalance(address user, uint256 amount) external {
        collateralBalance[user] = amount;
    }
}
