// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Pool} from "../pool/Pool.sol";
import {LendToken} from "../pool/tokenization/LendToken.sol";

contract EchidnaTest {
    Pool public pool;
    LendToken public lendToken;
    
    constructor() {
        // Deploy LendToken first
        lendToken = new LendToken();
        // Deploy Pool with LendToken address
        pool = new Pool(address(lendToken));
        // Transfer ownership of LendToken to Pool
        lendToken.transferOwnership(address(pool));
    }

    // Test interest rate properties
    function testInterestRateInvariants(uint256 utilization) public view returns (bool) {
        // Bound utilization to 0-100
        utilization = utilization % 101;
        
        uint256 rate = pool.calculateInterest(utilization);
        
        // Interest rate invariants
        bool baseRateCheck = rate >= pool.BASE_RATE();
        bool maxRateCheck = rate <= (pool.BASE_RATE() + pool.SLOPE1() + pool.SLOPE2());
        bool optimalCheck = true;
        
        // Check rate increase at optimal utilization
        if (utilization > pool.OPTIMAL_UTILIZATION()) {
            uint256 beforeOptimal = pool.calculateInterest(pool.OPTIMAL_UTILIZATION());
            optimalCheck = rate > beforeOptimal;
        }
        
        return baseRateCheck && maxRateCheck && optimalCheck;
    }

    // Test slope increases after optimal utilization
    function testSlopeIncrease(uint256 util1, uint256 util2) public view returns (bool) {
        // Bound utilizations
        util1 = util1 % 80;  // Before optimal
        util2 = (util2 % 20) + 80;  // After optimal
        
        uint256 rate1 = pool.calculateInterest(util1);
        uint256 rate2 = pool.calculateInterest(util2);
        
        return rate2 > rate1;
    }
} 