//SPDX-License-Identifier: MIT
pragma solidity ^0.8.9;

import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/security/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/security/PausableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/utils/SafeERC20Upgradeable.sol";


interface IxGRINToken {
    function mint(address _to, uint256 _value) external returns (bool);

    function burn(address _from, uint256 _value) external returns (bool);
}

contract GrinFarmV1 is
    Initializable,
    UUPSUpgradeable,
    OwnableUpgradeable,
    ReentrancyGuardUpgradeable,
    PausableUpgradeable
{
    using SafeERC20Upgradeable for IERC20Upgradeable;
    using SafeERC20Upgradeable for IxGRINToken;

    /* ========== STATE VARIABLES ========== */

    /// @notice GRIN token which will deposited to GrinFarm.
    IERC20Upgradeable public GRIN;
    /// @notice xGRIN token which can be minted in GrinFarm.
    IxGRINToken public xGRIN;
    /// @notice unlocking period is needed to redeem xGRIN for GRIN.
    uint256 public lockingPeriod;
    /// @notice pending xGRIN to burn that started unlocking period.
    uint256 public pendingxGRIN;
    /// @notice pending GRIN to be claimed that started unlockiing period.
    uint256 public pendingGRIN;

    mapping(address => WithdrawInfo[]) public withdrawInfoOf;

    struct WithdrawInfo {
        uint256 unlockTime;
        uint256 xGRINAmount;
        uint256 GRINAmount;
    }

    event Unstake(uint256 redeemedxGRIN, uint256 grinQueued);
    event ClaimUnlockedGRIN(uint256 withdrawnGRIN, uint256 burnedxGRIN);
    event Stake(uint256 stakedGRIN, uint256 mintedxGRIN);
    event FeesReceived(address indexed caller, uint256 amount);

    /* ========== Restricted Function  ========== */

    function setLockingPeriod(uint256 _lockingPeriod) external onlyOwner {
        lockingPeriod = _lockingPeriod;
    }

    function setInitialInfo(
        address _GRIN,
        uint256 _lockingPeriod,
        address _xGRIN
    ) external onlyOwner {
        xGRIN = IxGRINToken(_xGRIN);
        GRIN = IERC20Upgradeable(_GRIN);
        lockingPeriod = _lockingPeriod;
    }

    /**
        @notice Initialize UUPS upgradeable smart contract.
     */
    function initialize() external initializer {
        __Ownable_init();
        __ReentrancyGuard_init();
        __Pausable_init();
    }

    /**
        @notice restrict upgrade to only owner.
     */
    function _authorizeUpgrade(address newImplementation)
        internal
        virtual
        override
        onlyOwner
    {}

    /**
        @notice pause contract functions.
     */
    function pause() external onlyOwner whenNotPaused {
        _pause();
    }

    /**
        @notice unpause contract functions.
     */
    function unpause() external onlyOwner whenPaused {
        _unpause();
    }

    /* ========== External Function  ========== */

    /**
        @notice stake GRIN for xGRIN
        @param _amount The amount of GRIN to deposit
     */
    function stake(uint256 _amount) external whenNotPaused nonReentrant {
        require(_amount > 0, "Stake GRIN amount grinuld be bigger than 0");
        require(
            GRIN.balanceOf(msg.sender) >= _amount,
            "Not enough GRIN amount to stake."
        );
        GRIN.safeTransferFrom(msg.sender, address(this), _amount);
        uint256 grinAmount = GRIN.balanceOf(address(this)) - pendingGRIN - _amount;
        uint256 xGRINAmount = xGRIN.totalSupply() - pendingxGRIN;

        uint256 xGRINToGet;
        if (grinAmount == 0) {
            xGRINToGet = _amount;
        } else {
            xGRINToGet = (_amount * xGRINAmount * 1e18) / grinAmount;
            xGRINToGet /= 1e18;
        }

        xGRIN.mint(msg.sender, xGRINToGet);

        emit Stake(_amount, xGRINToGet);
    }

    /**
        @notice Return xGRIN for GRIN which is compounded over time. It needs unlocking period.
        @param _amount The amount of xGRIN to redeem
     */
    function unstake(uint256 _amount) external whenNotPaused nonReentrant {
        require(_amount > 0, "Redeem xGRIN grinuld be bigger than 0");
        require(
            xGRIN.balanceOf(msg.sender) >= _amount,
            "Not enough xGRIN amount to unstake."
        );
        xGRIN.safeTransferFrom(msg.sender, address(this), _amount);

        uint256 grinAmount = GRIN.balanceOf(address(this)) - pendingGRIN;
        uint256 xGRINAmount = xGRIN.totalSupply() - pendingxGRIN;

        uint256 grinToReturn = (_amount * grinAmount * 1e18) / xGRINAmount;
        uint256 endTime = block.timestamp + lockingPeriod;

        grinToReturn /= 1e18;

        withdrawInfoOf[msg.sender].push(
            WithdrawInfo({
                unlockTime: endTime,
                xGRINAmount: _amount,
                GRINAmount: grinToReturn
            })
        );

        pendingGRIN += grinToReturn;
        pendingxGRIN += _amount;

        emit Unstake(_amount, grinToReturn);
    }

    /**
        @notice Claim GRIN which unlocking period has been ended. 
     */
    function claimUnlockedGRIN() external whenNotPaused nonReentrant {
        (
            uint256 withdrawableGRIN,
            uint256 totalBurningxGRIN
        ) = _computeWithdrawableGRIN(msg.sender);
        require(
            withdrawableGRIN > 0 && totalBurningxGRIN > 0,
            "This address has no withdrawalbe GRIN"
        );

        xGRIN.burn(address(this), totalBurningxGRIN);
        GRIN.safeTransfer(msg.sender, withdrawableGRIN);

        emit ClaimUnlockedGRIN(withdrawableGRIN, totalBurningxGRIN);
    }

    /**
        @notice Deposit protocol fees into the contract, to be distributed to stakers.
        @param _amount Amount of the token to deposit
     */
    function depositFee(uint256 _amount) external {
        require(_amount > 0, "Deposit amount grinuld be bigger than 0");
        GRIN.safeTransferFrom(msg.sender, address(this), _amount);
        emit FeesReceived(msg.sender, _amount);
    }

    /* ========== Internal Function  ========== */

    /**
        @notice Update user's withdrawable info when inidividual unlocking is expired. 
        @param _user address of user which update withdrawable GRIN array.
     */
    function _computeWithdrawableGRIN(address _user)
        internal
        returns (uint256, uint256)
    {
        uint256 withdrawableGRIN = 0;
        uint256 totalBurningxGRIN = 0;

        WithdrawInfo[] storage withdrawableInfos = withdrawInfoOf[_user];

        uint256 withdrawableInfosLength = withdrawableInfos.length;
        WithdrawInfo[] memory newList = new WithdrawInfo[](
            withdrawableInfosLength
        );
        uint256 newListIndex = 0;

        for (uint256 i = 0; i < withdrawableInfosLength; i++) {
            WithdrawInfo storage withdrawInfo = withdrawableInfos[i];
            if (withdrawInfo.unlockTime <= block.timestamp) {
                withdrawableGRIN += withdrawInfo.GRINAmount;
                totalBurningxGRIN += withdrawInfo.xGRINAmount;
            } else {
                newList[newListIndex++] = withdrawInfo;
            }
        }

        uint256 emptyArrayCount = 0;

        for (uint256 i = 0; i < withdrawableInfosLength; i++) {
            if (newList[i].unlockTime == 0) {
                emptyArrayCount++;
            }
        }

        delete withdrawInfoOf[_user];

        if (emptyArrayCount != withdrawableInfosLength) {
            for (
                uint256 i = 0;
                i < withdrawableInfosLength - emptyArrayCount;
                i++
            ) {
                withdrawInfoOf[_user].push(newList[i]);
            }
        }

        if (withdrawableGRIN != 0 && totalBurningxGRIN != 0) {
            pendingGRIN -= withdrawableGRIN;
            pendingxGRIN -= totalBurningxGRIN;
        }
        return (withdrawableGRIN, totalBurningxGRIN);
    }

    /* ========== View Function  ========== */

    /**
        @notice Compute Withdrawable GRIN at given time.
     */
    function getRedeemableGRIN() external view returns (uint256) {
        WithdrawInfo[] memory withdrawableInfos = withdrawInfoOf[msg.sender];
        uint256 withdrawableGRIN;

        for (uint256 i = 0; i < withdrawableInfos.length; i++) {
            WithdrawInfo memory withdrawInfo = withdrawableInfos[i];
            if (withdrawInfo.unlockTime <= block.timestamp) {
                withdrawableGRIN += withdrawInfo.GRINAmount;
            }
        }
        return withdrawableGRIN;
    }

    /**
        @notice You grinuld devide return value by 10^7 to get a right number.
     */
    function getxGRINExchangeRate() external view returns (uint256) {
        uint256 grinAmount = GRIN.balanceOf(address(this)) - pendingGRIN;
        if (grinAmount == 0) {
            return 1 * 1e7;
        } else {
            uint256 xGRINAmount = xGRIN.totalSupply() - pendingxGRIN;
            return (grinAmount * 1e7) / xGRINAmount;
        }
    }

    /**
        @notice Update user's withdrawable info when inidividual unlocking is expired. 
        @param _user address of user which update withdrawable GRIN array.
     */
    function getUserWithdrawInfos(address _user)
        external
        view
        returns (WithdrawInfo[] memory)
    {
        WithdrawInfo[] memory withdrawableInfos = withdrawInfoOf[_user];
        WithdrawInfo[] memory info = new WithdrawInfo[](
            withdrawableInfos.length
        );
        for (uint256 i = 0; i < withdrawableInfos.length; i++) {
            info[i] = withdrawableInfos[i];
        }
        return info;
    }
}