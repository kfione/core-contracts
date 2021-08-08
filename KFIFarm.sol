// SPDX-License-Identifier: MIT
pragma experimental ABIEncoderV2;
pragma solidity 0.6.12;

import "./ERC20.sol";
import "./Address.sol";
import "./SafeERC20.sol";
import "./Ownable.sol";
import "./IPrice.sol";
import "./ReentrancyGuard.sol";


abstract contract KFIToken is ERC20 {
    function mint(address _to, uint256 _amount) public virtual;
}

/**
 * @title IStrategy
 * @dev As for the core farming strategy, every contract with KFI farm needs to be realized
 */
interface IStrategy {

    /**
     * @dev The total amount of tokens secured by all accounts
     */
    function totalStaked() external view returns (uint256);

    /**
     * @dev Sum of shares allocated to all accounts
     */
    function totalShared() external view returns (uint256);

    /**
     * @dev Withdraw income and reinvest
     */
    function earn() external;

    /**
     * @dev Deposit and calculate the allocated share
     */
    function deposit(address _userAddress, uint256 _wantAmt)
    external
    returns (uint256);

    /**
     * @dev Withdraw and calculate the share of deduction
     */
    function withdraw(address _userAddress, uint256 _wantAmt)
    external
    returns (uint256);

    /**
     * @dev Total TVL of all accounts
     */
    function tvl() external view returns (uint256);

    /**
     * @dev Total TVL of a single account
     */
    function userTvl(uint256 userShare) external view returns (uint256);

    /**
     * @dev Pool's data info
     * @return tvl deposit stakeTokenPrice controllerFee maxEnterFee withdrawFee
     */
    function poolDataInfo(uint256 u, address addr)
    external
    view
    returns (
        uint256,
        uint256,
        uint256,
        uint256,
        uint256,
        uint256
    );


    function apyInfo(uint256 everyBlockReward)  external view returns (uint256,uint256);

}

contract KFIFarm is Ownable, ReentrancyGuard {

    using SafeMath for uint256;
    using SafeERC20 for IERC20;
    using Address for address;

    address public govAddress;
    bool public allowContractAddr = false;
    mapping(address => bool) public whiteContractAddr;
    bool public isEmergencyWithdraw = false;


    // all strategy pools
    PoolInfo[] public poolInfo;
    // every pool userinfo
    mapping(uint256 => mapping(address => UserInfo)) public userInfo;
    uint256 public totalAllocPoint = 0;
    address public kfiAddress;
    address public priceAddr;
    uint256 public ownerKfiRewardRate = 100; // 12%
    uint256 public kfiMaxSupply = 100000000e18;
    uint256 public kfiPerBlock = 0; // KFI tokens created per block
    uint256 public startBlock = 4740000; //https://bscscan.com/block/countdown/3888888


    struct UserInfo {
        uint256 shares;
        uint256 rewardDebt;
    }

    struct PoolInfo {
        IERC20 stakeToken;
        uint256 allocPoint;
        uint256 lastRewardBlock;
        uint256 accKfiPerShare;
        address strategy;
    }

    constructor(address _kfiAddress,address _priceAddr) public {
        govAddress = tx.origin;
        kfiAddress = _kfiAddress;
        priceAddr = _priceAddr;
    }

    event Deposit(address indexed user, uint256 indexed pid, uint256 amount);
    event Withdraw(address indexed user, uint256 indexed pid, uint256 amount);
    event TakeKfiReward(address indexed user, uint256 indexed pid, uint256 amount);
    event EmergencyWithdraw(address indexed user, uint256 indexed pid, uint256 amount);

    function poolLength() public view returns (uint256) {
        return poolInfo.length;
    }


    /**
     * @dev pool detail data info
     */
    function poolDataInfo(uint256 _pid)
    public
    view
    returns (
        uint256,
        uint256,
        uint256,
        uint256,
        uint256,
        uint256
    )
    {
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][msg.sender];
        return IStrategy(pool.strategy).poolDataInfo(user.shares, msg.sender);
    }


    /**
     * @dev pool detail data info
     */
    function apyInfo(uint256 _pid) public view returns (uint256, uint256 ) {
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][msg.sender];

        uint256 everyBlockReward = 0;
        if(totalAllocPoint>0){
            everyBlockReward = kfiPerBlock.mul(pool.allocPoint).div(totalAllocPoint);
        }

        return IStrategy(pool.strategy).apyInfo(everyBlockReward);
    }



    /**
     * @dev Total TVL of all pools and total TVL of all accounts
     */
    function tvlInfo() public view returns (uint256, uint256) {
        uint256 totalTvl = 0;
        uint256 userTotalTvl = 0;
        uint256 length = poolInfo.length;
        for (uint256 pid = 0; pid < length; ++pid) {
            uint256 tvl = IStrategy(poolInfo[pid].strategy).tvl();
            totalTvl = totalTvl.add(tvl);
            UserInfo memory user = userInfo[pid][msg.sender];
            uint256 userTvl = IStrategy(poolInfo[pid].strategy).userTvl(user.shares);
            userTotalTvl = userTotalTvl.add(userTvl);
        }
        return (totalTvl, userTotalTvl);
    }

    /**
     * @dev KFIInfo
     */
    function kfiInfo() public view returns (uint256, uint256) {

        uint256 totalPendingKfi = 0;
        uint256 length = poolInfo.length;
        for (uint256 pid = 0; pid < length; ++pid) {
            uint256 pKfi = this.pendingKfi(pid,msg.sender);
            totalPendingKfi = totalPendingKfi.add(pKfi);
        }
        uint256 kfiPrice = IPrice(priceAddr).coinPrice(kfiAddress);
        return (totalPendingKfi,kfiPrice);
    }

    /**
     * @dev mint kfi to dao
     */
    function mintToDao(address _daoAddress,uint256 _amt) public onlyAllowGov{
        KFIToken(kfiAddress).mint(_daoAddress, _amt);
    }


    /**
     * @dev Withdraw income and reinvest
     */
    function earnAll() public nonReentrant {
        uint256 length = poolInfo.length;
        for (uint256 pid = 0; pid < length; ++pid) {
            IStrategy(poolInfo[pid].strategy).earn();
        }
    }

    /**
    * @dev Withdraw income and reinvest
    */
    function earn(uint256 _pid) public nonReentrant {
        IStrategy(poolInfo[_pid].strategy).earn();
    }


    /**
     * @dev Add new strategy pool
     */
    function add( uint256 _allocPoint, bool _withUpdate, IERC20 _stakeToken, address _strategy) public onlyAllowGov {
        if (_withUpdate) {
            massUpdatePools();
        }
        uint256 lastRewardBlock = block.number > startBlock ? block.number : startBlock;
        totalAllocPoint = totalAllocPoint.add(_allocPoint);
        poolInfo.push(
            PoolInfo({
        stakeToken: _stakeToken,
        allocPoint: _allocPoint,
        lastRewardBlock: lastRewardBlock,
        accKfiPerShare: 0,
        strategy: _strategy
        })
        );
    }

    // Update the given pool's KFI allocation point. Can only be called by the owner.
    function setPoolInfo(uint256 _pid, uint256 _allocPoint, bool _withUpdate ) public onlyOwner {
        if (_withUpdate) {
            massUpdatePools();
        }
        totalAllocPoint = totalAllocPoint.sub(poolInfo[_pid].allocPoint).add(_allocPoint);
        poolInfo[_pid].allocPoint = _allocPoint;
    }

    // Update reward variables for all pools. Be careful of gas spending!
    function massUpdatePools() public {
        uint256 length = poolInfo.length;
        for (uint256 pid = 0; pid < length; ++pid) {
            updatePool(pid);
        }
    }

    // Update reward variables of the given pool to be up-to-date.
    function updatePool(uint256 _pid) public {
        PoolInfo storage pool = poolInfo[_pid];
        if (block.number <= pool.lastRewardBlock) {
            return;
        }
        uint256 totalShared = IStrategy(pool.strategy).totalShared();
        if (totalShared == 0) {
            pool.lastRewardBlock = block.number;
            return;
        }
        uint256 multiplier = getMultiplier(pool.lastRewardBlock, block.number);
        if (multiplier <= 0) {
            return;
        }
        if(totalAllocPoint>0){
            uint256 kfiReward = multiplier.mul(kfiPerBlock).mul(pool.allocPoint).div(totalAllocPoint);
            KFIToken(kfiAddress).mint(owner(), kfiReward.mul(ownerKfiRewardRate).div(1000));
            KFIToken(kfiAddress).mint(address(this), kfiReward);
            if(totalShared>0){
                pool.accKfiPerShare = pool.accKfiPerShare.add(kfiReward.mul(1e12).div(totalShared));
            }
        }

        pool.lastRewardBlock = block.number;
    }

    // Return reward multiplier over the given _from to _to block.
    function getMultiplier(uint256 _from, uint256 _to) public view returns (uint256) {
        if (IERC20(kfiAddress).totalSupply() >= kfiMaxSupply) {
            return 0;
        }
        return _to.sub(_from);
    }


    /**
     * @dev Update pool stakeToken
     */
    function updatePoolStakeToken(uint256 _pid, IERC20 _stakeToken) public onlyAllowGov {
        poolInfo[_pid].stakeToken = _stakeToken;
    }

    /**
     * @dev Update pool  strategy
     */
    function updatePoolStrategy(uint256 _pid,address _strategy) public onlyAllowGov {
        poolInfo[_pid].strategy = _strategy;
    }



    // View function to see pending KFI on frontend.
    function pendingKfi(uint256 _pid, address _user) external view returns (uint256) {
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][_user];
        uint256 accKfiPerShare = pool.accKfiPerShare;
        uint256 totalShared = IStrategy(pool.strategy).totalShared();
        if (block.number > pool.lastRewardBlock && totalShared > 0 && totalAllocPoint > 0) {
            uint256 multiplier = getMultiplier(pool.lastRewardBlock, block.number);
            uint256 kfiReward = multiplier.mul(kfiPerBlock).mul(pool.allocPoint).div(totalAllocPoint);
            accKfiPerShare = accKfiPerShare.add(kfiReward.mul(1e12).div(totalShared));
        }
        return user.shares.mul(accKfiPerShare).div(1e12).sub(user.rewardDebt);
    }

    // View function to see staked Want tokens on frontend.
    function stakedWantTokens(uint256 _pid, address _user) external view returns (uint256) {
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][_user];

        uint256 totalShared = IStrategy(pool.strategy).totalShared();
        uint256 totalStaked = IStrategy(poolInfo[_pid].strategy).totalStaked();
        if (totalShared == 0) {
            return 0;
        }
        return user.shares.mul(totalShared).div(totalShared);
    }


    /**
     * @dev Deposit tokens from KFIFarm
     */
    function deposit(uint256 _pid, uint256 _wantAmt) public nonReentrant {
        require(supportAddr(msg.sender),"Not Support");
        updatePool(_pid);

        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][msg.sender];
        if (user.shares > 0) {
            uint256 pending = user.shares.mul(pool.accKfiPerShare).div(1e12).sub(user.rewardDebt);
            if (pending > 0) {
                safeKfiTransfer(msg.sender, pending);
            }
        }
        if (_wantAmt > 0) {
            pool.stakeToken.safeTransferFrom(
                address(msg.sender),
                address(this),
                _wantAmt
            );
            pool.stakeToken.safeIncreaseAllowance(pool.strategy, _wantAmt);
            uint256 sharesAdded = IStrategy(poolInfo[_pid].strategy).deposit(
                msg.sender,
                _wantAmt
            );
            user.shares = user.shares.add(sharesAdded);
        }
        user.rewardDebt = user.shares.mul(pool.accKfiPerShare).div(1e12);
        emit Deposit(msg.sender, _pid, _wantAmt);
    }


    /**
     * @dev Take KFI Reward
     */
    function withdrawReward(uint256 _pid) public nonReentrant {
        require(supportAddr(msg.sender),"Not Support");
        updatePool(_pid);

        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][msg.sender];

        uint256 totalStaked = IStrategy(poolInfo[_pid].strategy).totalStaked();
        uint256 totalShared = IStrategy(poolInfo[_pid].strategy).totalShared();

        require(user.shares > 0, "user.shares is 0");
        require(totalShared > 0, "sharesTotal is 0");

        // Withdraw pending KFI
        uint256 pending = user.shares.mul(pool.accKfiPerShare).div(1e12).sub(user.rewardDebt);
        if (pending > 0) {
            safeKfiTransfer(msg.sender, pending);
        }
        user.rewardDebt = user.shares.mul(pool.accKfiPerShare).div(1e12);
        emit TakeKfiReward(msg.sender, _pid, pending);
    }



    // Withdraw without caring about rewards. EMERGENCY ONLY.
    function emergencyWithdraw(uint256 _pid) public nonReentrant {
        require(isEmergencyWithdraw,"not support");
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][msg.sender];

        uint256 totalStaked = IStrategy(poolInfo[_pid].strategy).totalStaked();
        uint256 sharesTotal = IStrategy(poolInfo[_pid].strategy).totalShared();
        uint256 amount = user.shares.mul(totalStaked).div(sharesTotal);
        IStrategy(poolInfo[_pid].strategy).withdraw(msg.sender, amount);
        uint256 stakeBalance = IERC20(pool.stakeToken).balanceOf(address(this));
        if (stakeBalance <= amount) {
            amount = stakeBalance;
        }
        pool.stakeToken.safeTransfer(address(msg.sender), amount);
        emit EmergencyWithdraw(msg.sender, _pid, amount);
        user.shares = 0;
        user.rewardDebt = 0;
    }

    /**
     * @dev Withdraw tokens from KFIFarm.
     */
    function withdraw(uint256 _pid, uint256 _wantAmt) public nonReentrant {

        require(supportAddr(msg.sender),"Not Support");

        updatePool(_pid);

        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][msg.sender];

        uint256 totalStaked = IStrategy(poolInfo[_pid].strategy).totalStaked();
        uint256 totalShared = IStrategy(poolInfo[_pid].strategy).totalShared();

        require(user.shares > 0, "user.shares is 0");
        require(totalShared > 0, "sharesTotal is 0");

        // Withdraw pending KFI
        uint256 pending = user.shares.mul(pool.accKfiPerShare).div(1e12).sub(user.rewardDebt);
        if (pending > 0) {
            safeKfiTransfer(msg.sender, pending);
        }

        // Withdraw want tokens
        uint256 amount = user.shares.mul(totalStaked).div(totalShared);
        if (_wantAmt > amount) {
            _wantAmt = amount;
        }
        if (_wantAmt > 0) {
            uint256 sharesRemoved = IStrategy(poolInfo[_pid].strategy).withdraw(msg.sender,_wantAmt);
            if (sharesRemoved > user.shares) {
                user.shares = 0;
            } else {
                user.shares = user.shares.sub(sharesRemoved);
            }
            uint256 stakeBalance = IERC20(pool.stakeToken).balanceOf(address(this));
            if (stakeBalance <= _wantAmt) {
                _wantAmt = stakeBalance;
            }
            pool.stakeToken.safeTransfer(address(msg.sender), _wantAmt);
        }
        user.rewardDebt = user.shares.mul(pool.accKfiPerShare).div(1e12);
        emit Withdraw(msg.sender, _pid, _wantAmt);
    }

    function withdrawAll(uint256 _pid) public nonReentrant {
        require(supportAddr(msg.sender),"Not Support");

        uint256 _wantAmt = uint256(-1);
        updatePool(_pid);

        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][msg.sender];

        uint256 totalStaked = IStrategy(poolInfo[_pid].strategy).totalStaked();
        uint256 totalShared = IStrategy(poolInfo[_pid].strategy).totalShared();

        require(user.shares > 0, "user.shares is 0");
        require(totalShared > 0, "sharesTotal is 0");

        // Withdraw pending KFI
        uint256 pending = user.shares.mul(pool.accKfiPerShare).div(1e12).sub(user.rewardDebt);
        if (pending > 0) {
            safeKfiTransfer(msg.sender, pending);
        }

        // Withdraw want tokens
        uint256 amount = user.shares.mul(totalStaked).div(totalShared);
        if (_wantAmt > amount) {
            _wantAmt = amount;
        }
        if (_wantAmt > 0) {
            uint256 sharesRemoved = IStrategy(poolInfo[_pid].strategy).withdraw(msg.sender,_wantAmt);
            if (sharesRemoved > user.shares) {
                user.shares = 0;
            } else {
                user.shares = user.shares.sub(sharesRemoved);
            }
            uint256 stakeBalance = IERC20(pool.stakeToken).balanceOf(address(this));
            if (stakeBalance <= _wantAmt) {
                _wantAmt = stakeBalance;
            }
            pool.stakeToken.safeTransfer(address(msg.sender), _wantAmt);
        }
        user.rewardDebt = user.shares.mul(pool.accKfiPerShare).div(1e12);
        emit Withdraw(msg.sender, _pid, _wantAmt);
    }


    // Safe KFI transfer function, just in case if rounding error causes pool to not have enough
    function safeKfiTransfer(address _to, uint256 _kfiAmt) internal {
        uint256 kfiBal = IERC20(kfiAddress).balanceOf(address(this));
        if (_kfiAmt >= kfiBal) {
            IERC20(kfiAddress).transfer(_to, kfiBal);
        } else {
            IERC20(kfiAddress).transfer(_to, _kfiAmt);
        }
    }

    function setKfiAddress(address _kfiAddress) public virtual onlyAllowGov {
        kfiAddress = _kfiAddress;
    }

    function setKfiPerBlock(uint256 _amt) public virtual onlyAllowGov {
        massUpdatePools();
        kfiPerBlock = _amt;
    }

    function setPriceAddress(address _priceAddr) public virtual onlyAllowGov {
        priceAddr = _priceAddr;
    }

    function setStartBlock(uint256 _startBlock)public virtual onlyAllowGov {
        startBlock = _startBlock;
    }

    function setAllowContractAddr(bool _bool)public virtual onlyAllowGov {
        allowContractAddr = _bool;
    }

    function addWhiteContractAddr(address _addr)public virtual onlyAllowGov {
        if(address(_addr).isContract()){
            whiteContractAddr[_addr] = true;
        }
    }

    function delWhiteContractAddr(address _addr)public virtual onlyAllowGov {
        if(address(_addr).isContract()){
            whiteContractAddr[_addr] = false;
        }
    }

    function setIsEmergencyWithdraw(bool _bool)public virtual onlyAllowGov{
        isEmergencyWithdraw = _bool;
    }


    function supportAddr(address _addr) internal view returns (bool) {
        if(allowContractAddr){
            return true;
        }

        bool contractAddr = address(_addr).isContract();
        if(!contractAddr || whiteContractAddr[_addr]){
            return true;
        }

        return false;
    }

    modifier onlyAllowGov() {
        require(msg.sender == govAddress || msg.sender == owner(), "!gov");
        _;
    }


}

