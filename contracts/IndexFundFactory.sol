//SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.9;

import "@openzeppelin/contracts/access/Ownable.sol";
import "./BIIndexFund.sol";

contract IndexFundFactory is Ownable{
    struct FundInfo {
        address lpAddr;
        address token0;
        address token1;
    }

    /* ========== STATE VARIABLES ========== */

    mapping(address => FundInfo) public fundAtAddress;
    // This can be 0 to 100. e.g. 3 means 3% of bribe will be used for maintanance fee.
    int24 public RESOLUTION = 5;
    address[] private fundList;
    uint256 private fundCount;

    IMakerOrderManager public  makerOrderManager;

    /* ========== Restricted Function  ========== */

    constructor(
        IMakerOrderManager _makerOrderManage)  {
        makerOrderManager = _makerOrderManage;
    }



    function setRESOLUTION(int24 _RESOLUTION)
        external
        onlyOwner
    {
        RESOLUTION = _RESOLUTION;
    }

    /* ========== External Function  ========== */

    function createBIIndexFund( 
        uint256 _rebalancingPeriod,
        uint256 _rebalancingThreshold,
        address _token0,
        address _token1,
        address _operator,
        int24 _RESOLUTION) external returns (address){

        BIIndexFund bribe = new BIIndexFund(
            owner(),
            _rebalancingPeriod,
            _rebalancingThreshold,
            _token0,
             _token1,
            _operator,
            makerOrderManager,
            _RESOLUTION
        );

        fundCount++;
        fundAtAddress[address(bribe)] = FundInfo({
                lpAddr: address(bribe),
                token0: _token0,
                token1: _token1
            });
        
        fundList.push(address(bribe));

        return(address(bribe));
    }

   
    function getFundCount() external view returns (uint256) {
        return fundCount;
    }

    function getFundAddressAt(uint256 _index) external view returns (address) {
        return fundList[_index];
    }

}