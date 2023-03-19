//SPDX-License-Identifier: MIT
pragma solidity ^0.8.9;
import "@openzeppelin/contracts/security/Pausable.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@gridexprotocol/core/contracts/interfaces/IGrid.sol";
import "@gridexprotocol/core/contracts/interfaces/IGridFactory.sol";
import "@gridexprotocol/core/contracts/libraries/GridAddress.sol";
import "@gridexprotocol/core/contracts/libraries/BoundaryMath.sol";
import "./interfaces/IMakerOrderManager.sol";

interface IERC20 {
    function totalSupply() external view returns (uint256);
    function balanceOf(address account) external view returns (uint256);
    function transfer(address to, uint256 amount) external returns (bool);
    function allowance(address owner, address spender) external view returns (uint256);
    function approve(address spender, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
    function name() external view returns (string memory);
    function symbol() external view returns (string memory);
    function decimals() external view returns (uint8);
    function burn(uint amount) external;
}
library SafeMath {
    function add(uint256 a, uint256 b) internal pure returns (uint256) {
        uint256 c = a + b;
        require(c >= a, "SafeMath: addition overflow");

        return c;
    }

    function sub(uint256 a, uint256 b) internal pure returns (uint256) {
        return sub(a, b, "SafeMath: subtraction overflow");
    }

    function sub(uint256 a, uint256 b, string memory errorMessage) internal pure returns (uint256) {
        require(b <= a, errorMessage);
        uint256 c = a - b;

        return c;
    }

    function mul(uint256 a, uint256 b) internal pure returns (uint256) {
        if (a == 0) {
            return 0;
        }

        uint256 c = a * b;
        require(c / a == b, "SafeMath: multiplication overflow");

        return c;
    }

    function div(uint256 a, uint256 b) internal pure returns (uint256) {
        return div(a, b, "SafeMath: division by zero");
    }

    function div(uint256 a, uint256 b, string memory errorMessage) internal pure returns (uint256) {
        require(b > 0, errorMessage);
        uint256 c = a / b;

        return c;
    }

    function mod(uint256 a, uint256 b) internal pure returns (uint256) {
        return mod(a, b, "SafeMath: modulo by zero");
    }

    function mod(uint256 a, uint256 b, string memory errorMessage) internal pure returns (uint256) {
        require(b != 0, errorMessage);
        return a % b;
    }

    function ceilDiv(uint256 a, uint256 b) internal pure returns (uint256) {
        // (a + b - 1) / b can overflow on addition, so we distribute.
        return a / b + (a % b == 0 ? 0 : 1);
    }
}


library UQ112x112 {
    uint224 constant Q112 = 2**112;

    // encode a uint112 as a UQ112x112
    function encode(uint112 y) internal pure returns (uint224 z) {
        z = uint224(y) * Q112; // never overflows
    }

    // divide a UQ112x112 by a uint112, returning a UQ112x112
    function uqdiv(uint224 x, uint112 y) internal pure returns (uint224 z) {
        z = x / uint224(y);
    }
}


contract BIIndexFund is Ownable, Pausable{

    using SafeMath for uint256;
    using UQ112x112 for uint224;

    // ============ Start  of ERC20 =================

    event Transfer(address indexed from, address indexed to, uint amount);
    event Approval(address indexed holder, address indexed spender, uint amount);

    string public name = "BIIndexFund LP";
    string public constant symbol = "BILP";
    uint8 public decimals = 18;

    uint public totalSupply;

    mapping(address => uint) public balanceOf;
    mapping(address => mapping(address => uint)) public allowance;


    // ============ End of ERC20 =================

    IMakerOrderManager public immutable makerOrderManager;
    int24 public RESOLUTION;

    uint256 public constant VERSION = 1;

    IERC20 public lpToken;
    address public token0;
    address public token1;
    uint256 public rebalancingPeriod;
    uint256 public rebalancingThreshold;

    uint112 public reserve0;
    uint112 public reserve1;
    uint32 public blockTimestampLast;

    uint public price0CumulativeLast;
    uint public price1CumulativeLast;
    uint public kLast; 
    uint balance0;
    uint balance1;
    
    bool public entered;   

    address public operator; 

    event Sync(uint112 reserveA, uint112 reserveB);
    event AddLiquidity(address user, address token0, uint amount0, address token1, uint amount1, uint liquidity);
    event RemoveLiquidity(address user, address token0, uint amount0, address token1, uint amount1, uint liquidity);

    constructor(
        address _owner,
        uint256 _rebalancingPeriod,
        uint256 _rebalancingThreshold,
        address _token0,
        address _token1,
        address _operator,
        IMakerOrderManager _makerOrderManager,
        int24 _RESOLUTION
    ) {
        require(_token0 != _token1);
        _transferOwnership(_owner);

        token0 = _token0;
        token1 = _token1;
        rebalancingPeriod = _rebalancingPeriod;
        rebalancingThreshold = _rebalancingThreshold;
        operator = _operator;

        makerOrderManager = _makerOrderManager;
        RESOLUTION = _RESOLUTION;
    }

    function transfer(address _to, uint _value) public nonReentrant returns (bool) {
        decreaseBalance(msg.sender, _value);
        increaseBalance(_to, _value);

        emit Transfer(msg.sender, _to, _value);

        return true;
    }

    function transferFrom(address _from, address _to, uint _value) public nonReentrant returns (bool) {
        decreaseBalance(_from, _value);
        increaseBalance(_to, _value);

        allowance[_from][msg.sender] = allowance[_from][msg.sender].sub(_value);
        
        emit Transfer(_from, _to, _value);

        return true;
    }

    function _approve(address owner, address spender, uint value) private {
        allowance[owner][spender] = value;
        emit Approval(owner, spender, value);
    }

    function approve(address _spender, uint _value) public returns (bool) {
        require(_spender != address(0));
        _approve(msg.sender, _spender, _value);

        return true;
    }

    function _update() private {
        balance0 = IERC20(token0).balanceOf(address(this));
        balance1 = IERC20(token1).balanceOf(address(this));

        require(balance0 <= type(uint112).max&& balance1 <=type(uint112).max, 'OVERFLOW');

        uint32 blockTimestamp = uint32(block.timestamp % 2**32);
        uint32 timeElapsed = blockTimestamp - blockTimestampLast;
        
        if (timeElapsed > 0 && reserve0 != 0 && reserve1 != 0) {
            price0CumulativeLast += uint(UQ112x112.encode(reserve1).uqdiv(reserve0)) * timeElapsed;
            price1CumulativeLast += uint(UQ112x112.encode(reserve0).uqdiv(reserve1)) * timeElapsed;
        }
        reserve0 = uint112(balance0);
        reserve1 = uint112(balance1);
        blockTimestampLast = blockTimestamp;
        
        emit Sync(reserve0, reserve1);
    }

    // ======== Change supply & balance ========

    function increaseTotalSupply(uint amount) private {
        totalSupply = totalSupply.add(amount);
    }

    function decreaseTotalSupply(uint amount) private {
        totalSupply = totalSupply.sub(amount);
    }

    function increaseBalance(address user, uint amount) private {
        balanceOf[user] = balanceOf[user].add(amount);
    }

    function decreaseBalance(address user, uint amount) private {
        balanceOf[user] = balanceOf[user].sub(amount);
    }

    function getTokenSymbol(address token) private view returns (string memory) {
        return IERC20(token).symbol();
    }
   
    function getReserves() public view returns (uint112 _reserve0, uint112 _reserve1, uint32 _blockTimestampLast) {
        _reserve0 = reserve0;
        _reserve1 = reserve1;
        _blockTimestampLast = blockTimestampLast;
    }

    // ======== Add/remove Liquidity ========

    function addLiquidity(uint amount0, uint amount1, address user) private returns (uint real0, uint real1, uint amountLP) {
        require(amount0 != 0 && amount1 != 0);
        real0 = amount0;
        real1 = amount1;

        (uint pool0, uint pool1) = getCurrentPool();

        if (totalSupply == 0) {
            grabToken(token0, amount0);
            grabToken(token1, amount1);

            increaseTotalSupply(amount0);
            increaseBalance(user, amount0);

            amountLP = amount0;

            emit AddLiquidity(user, token0, amount0, token1, amount1, amount0);

            emit Transfer(address(0), user, amount0);
        }
        else {
            uint with0 = totalSupply.mul(amount0).div(pool0);
            uint with1 = totalSupply.mul(amount1).div(pool1);

            if (with0 < with1) {
                require(with0 > 0);

                grabToken(token0, amount0);

                real1 = with0.mul(pool1).ceilDiv(totalSupply);
                require(real1 <= amount1);

                grabToken(token1, real1);

                increaseTotalSupply(with0);
                increaseBalance(user, with0);

                amountLP = with0;

                emit AddLiquidity(user, token0, amount0, token1, real1, with0);

                emit Transfer(address(0), user, with0);
            }
            else {
                require(with1 > 0);

                grabToken(token1, amount1);

                real0 = with1.mul(pool0).ceilDiv(totalSupply);
                require(real0 <= amount0);

                grabToken(token0, real0);

                increaseTotalSupply(with1);
                increaseBalance(user, with1);

                amountLP = with1;

                emit AddLiquidity(user, token0, real0, token1, amount1, with1);

                emit Transfer(address(0), user, with1);
            }
        }

        _update();

        return (real0, real1, amountLP);
    }

    function addTokenLiquidityWithLimit(uint amount0, uint amount1, uint minAmount0, uint minAmount1, address user) public nonReentrant returns (uint real0, uint real1, uint amountLP) {
        (real0, real1, amountLP) = addLiquidity(amount0, amount1, user);
        require(real0 >= minAmount0, "minAmount0 is not satisfied");
        require(real1 >= minAmount1, "minAmount1 is not satisfied");
    }

    function removeLiquidityWithLimit(uint amount, uint minAmount0, uint minAmount1, address user) public nonReentrant returns (uint, uint) {
        require(amount != 0);

        (uint pool0, uint pool1) = getCurrentPool();

        uint amount0 = pool0.mul(amount).div(totalSupply);
        uint amount1 = pool1.mul(amount).div(totalSupply);

        require(amount0 >= minAmount0, "minAmount0 is not satisfied");
        require(amount1 >= minAmount1, "minAmount1 is not satisfied");

        decreaseTotalSupply(amount);
        decreaseBalance(msg.sender, amount);

        emit Transfer(msg.sender, address(0), amount);

        if (amount0 > 0) sendToken(token0, amount0, user);
        if (amount1 > 0) sendToken(token1, amount1, user);

        _update();

        emit RemoveLiquidity(msg.sender, token0, amount0, token1, amount1, amount);

        return (amount0, amount1);
    }


    function grabToken(address token, uint amount) private {
        uint userBefore = IERC20(token).balanceOf(msg.sender);
        uint thisBefore = IERC20(token).balanceOf(address(this));

        require(IERC20(token).transferFrom(msg.sender, address(this), amount), "grabToken failed");

        uint userAfter = IERC20(token).balanceOf(msg.sender);
        uint thisAfter = IERC20(token).balanceOf(address(this));

        require(userAfter.add(amount) == userBefore);
        require(thisAfter == thisBefore.add(amount));
    }

    function sendToken(address token, uint amount, address user) private {
        uint userBefore = IERC20(token).balanceOf(user);
        uint thisBefore = IERC20(token).balanceOf(address(this));

        require(IERC20(token).transfer(user, amount), "Exchange: sendToken failed");

        uint userAfter = IERC20(token).balanceOf(user);
        uint thisAfter = IERC20(token).balanceOf(address(this));

        require(userAfter == userBefore.add(amount), "Exchange: user balance not equal");
        require(thisAfter.add(amount) == thisBefore, "Exchange: this balance not equal");
    }

    function getCurrentPool() public view returns (uint, uint) {
        (uint pool0, uint pool1, ) = getReserves();

        return (pool0, pool1);
    }

    // Rebalancing 

    function rebalance() external view {
        require(operator == msg.sender,"Caller is not an operator");

    }

    function placeMakerOrderFortoken0(uint128 amount) external returns (uint256 orderId) {

        IERC20(token0).transferFrom(msg.sender, address(this), amount);

        IERC20(token0).approve(address(makerOrderManager), amount);

        // compute grid address
        address gridAddress = GridAddress.computeAddress(
            makerOrderManager.gridFactory(),
            GridAddress.gridKey(token0, token1, RESOLUTION)
        );
        IGrid grid = IGrid(gridAddress);

        (, int24 boundary, , ) = grid.slot0();
        // for this example, we will place a maker order at the current lower boundary of the grid
        int24 boundaryLower = BoundaryMath.getBoundaryLowerAtBoundary(boundary, RESOLUTION);
        IMakerOrderManager.PlaceOrderParameters memory parameters = IMakerOrderManager.PlaceOrderParameters({
            deadline: block.timestamp,
            recipient: address(this),
            tokenA: token0,
            tokenB: token1,
            resolution: RESOLUTION,
            zero: grid.token0() == token0, // token0 is token0 or not
            boundaryLower: boundaryLower,
            amount: amount
        });

        orderId = makerOrderManager.placeMakerOrder(parameters);
    }

    /// @notice place a maker order for token1
    /// @param amount The amount of token1 to place a maker order
    /// @return orderId The id of the maker order
    function placeMakerOrderFortoken1(uint128 amount) external returns (uint256 orderId) {
 
        IERC20(token1).transferFrom(msg.sender, address(this), amount);
        IERC20(token1).approve(address(makerOrderManager), amount);

        address gridAddress = GridAddress.computeAddress(
            makerOrderManager.gridFactory(),
            GridAddress.gridKey(token0, token1, RESOLUTION)
        );
        IGrid grid = IGrid(gridAddress);

        (, int24 boundary, , ) = grid.slot0();
        // for this example, we will place a maker order at the current lower boundary of the grid
        int24 boundaryLower = BoundaryMath.getBoundaryLowerAtBoundary(boundary, RESOLUTION);
        IMakerOrderManager.PlaceOrderParameters memory parameters = IMakerOrderManager.PlaceOrderParameters({
            deadline: block.timestamp,
            recipient: address(this),
            tokenA: token0,
            tokenB: token1,
            resolution: RESOLUTION,
            zero: grid.token0() == token1, // token0 is token1 or not
            boundaryLower: boundaryLower,
            amount: amount
        });

        orderId = makerOrderManager.placeMakerOrder(parameters);
    }

    /// @notice settle and collect the maker order
    function settleAndCollect(uint256 orderId) external returns (uint128 amount0, uint128 amount1) {
        // compute grid address
        address gridAddress = GridAddress.computeAddress(
            makerOrderManager.gridFactory(),
            GridAddress.gridKey(token0, token1, RESOLUTION)
        );

        (amount0, amount1) = IGrid(gridAddress).settleMakerOrderAndCollect(msg.sender, orderId, true);
    }
    
    // Modifier 

    modifier nonReentrant {
        require(!entered, "ReentrancyGuard: reentrant call");

        entered = true;

        _;

        entered = false;
    }

}