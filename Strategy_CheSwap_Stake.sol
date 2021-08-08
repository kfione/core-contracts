// SPDX-License-Identifier: MIT
pragma solidity 0.6.12;
import "./ERC20.sol";
import "./Address.sol";
import "./SafeERC20.sol";
import "./EnumerableSet.sol";
import "./Ownable.sol";
import "./IStrategyFarm.sol";
import "./ISwapRouter.sol";
import "./IPrice.sol";
import "./ReentrancyGuard.sol";
import "./Pausable.sol";

interface IWOKT is IERC20 {
    function deposit() external payable;
    function withdraw(uint256 wad) external;
}

/**
 * @title Strategy_KSwap_Core
 * @dev For target farms using kswap
 */
contract Strategy_CheSwap_Stake  is Ownable, ReentrancyGuard, Pausable {


    using SafeMath for uint256;
    using SafeERC20 for IERC20;

    bool public onlyGov = false;
    bool public buyUsdt = true;


    uint256 public totalStaked = 0;
    uint256 public totalShared = 0;

    address public stakeToken;
    address public strategyFarmAddr;

    address public govAddress;
    address public kfiFarmAddress;

    address public usdtAddr = address(0x382bB369d343125BfB2117af9c149795C6C65C50);
    address public uniRouterAddress = address(0x865bfde337C8aFBffF144Ff4C29f9404EBb22b15);
    address public kfiAddress = address(0xb8D9a5aa3f52DE1B8B08811A1155800b107B6156);
    address public priceAddr = address(0x30F57875d7a5aE7Df6b623843B764b3A4d8ace92);

    //CHE
    address public earnedAddress = address(0x8179D97Eb6488860d816e3EcAFE694a4153F216c);

    address public woktAddress = address(0x8F8526dbfd6E38E3D8307702cA8469Bae6C56C15);
    address public rewardsAddress = address(0xD8fB65e637f2225E952eADFc66AeAC4635eD84F3);
    address public buyBackAddress = address(0x0281b4318fdE7d5fab1c3C4619f887b9b3CEC9cF);


    address[] public earnedToUsdtPath;
    address[] public earnedToKfiPath;
    address[] public earnToStakePath;




    uint256 public controllerFee = 500; // 5%;
    uint256 public constant controllerFeeMax = 10000; // 100 = 1%
    uint256 public constant controllerFeeUL = 3000;

    uint256 public buyBackRate = 0; // 250;
    uint256 public constant buyBackRateMax = 10000; // 100 = 1%
    uint256 public constant buyBackRateUL = 5000;

    uint256 public entranceFeeFactor = 10000; // < 9990 = 0.1% entrance fee - goes to pool + prevents front-running
    uint256 public constant entranceFeeFactorMax = 10000;
    uint256 public constant entranceFeeFactorLL = 9950; // 0.5% is the max entrance fee settable. LL = lowerlimit

    uint256 public withdrawFeeFactor = 9990; // 0.1% withdraw fee - goes to pool
    uint256 public constant withdrawFeeFactorMax = 10000;
    uint256 public constant withdrawFeeFactorLL = 9900; // 1% is the max entrance fee settable. LL = lowerlimit

    uint256 public slippageFactor = 950; // 5% default slippage tolerance
    uint256 public constant slippageFactorUL = 995;

    uint256 public earnLimit = 2*1e18;
    uint256 sencondsReward = 0;
    uint256 lastBlock = 0;
    uint256 lastStake = 0;
    uint256 diffBlock = 0;

    event SetSettings(
        uint256 _entranceFeeFactor,
        uint256 _withdrawFeeFactor,
        uint256 _controllerFee,
        uint256 _buyBackRate,
        uint256 _slippageFactor
    );

    event SetOnlyGov(bool _onlyGov);
    event SetHourBlockNum(uint256 _hourBlockNum);
    event UpdateAddress(address _address);
    event UpdatePath(address[] _address);
    event SetBuyUsdt(bool _bool);


    constructor(
        address[] memory _addresses
    ) public {
        stakeToken = _addresses[0];
        strategyFarmAddr = _addresses[1];
        kfiFarmAddress =  _addresses[2];
        govAddress = msg.sender;

        earnToStakePath = [earnedAddress,stakeToken];
        earnedToUsdtPath = [earnedAddress,usdtAddr];
        earnedToKfiPath = [earnedAddress,kfiAddress];
        transferOwnership(kfiFarmAddress);
    }


    function deposit(address _userAddress, uint256 _wantAmt) public virtual onlyOwner blockPer nonReentrant whenNotPaused returns (uint256) {
        IERC20(stakeToken).safeTransferFrom(
            address(msg.sender),
            address(this),
            _wantAmt
        );
        if (entranceFeeFactor < entranceFeeFactorMax) {
            uint256 entranceFee = _wantAmt.sub(_wantAmt.mul(entranceFeeFactor).div(entranceFeeFactorMax));
            _wantAmt = _wantAmt.sub(entranceFee);
            IERC20(stakeToken).safeTransfer(rewardsAddress, entranceFee);
        }

        uint256 sharesAdded = _wantAmt;
        if (totalStaked > 0 && totalShared > 0) {
            sharesAdded = _wantAmt.mul(totalShared).div(totalStaked);
        }
        totalShared = totalShared.add(sharesAdded);
        _farm();
        return sharesAdded;
    }

    function farm() public virtual nonReentrant {
        _farm();
    }

    function _farm() internal virtual {
        uint256 wantAmt = IERC20(stakeToken).balanceOf(address(this));
        totalStaked = totalStaked.add(wantAmt);
        IERC20(stakeToken).safeIncreaseAllowance(strategyFarmAddr, wantAmt);
        IStrategyFarm(strategyFarmAddr).deposit(wantAmt);
    }

    function _unfarm(uint256 _wantAmt) internal virtual {
        IStrategyFarm(strategyFarmAddr).withdraw(_wantAmt);
    }

    function withdraw(address _userAddress, uint256 _wantAmt) public virtual onlyOwner blockPer nonReentrant returns (uint256) {
        require(_wantAmt > 0, "_wantAmt <= 0");
        require(totalStaked > 0, "totalStaked <= 0");
        uint256 sharesRemoved = _wantAmt.mul(totalShared).div(totalStaked);
        if (sharesRemoved > totalShared) {
            sharesRemoved = totalShared;
        }
        totalShared = totalShared.sub(sharesRemoved);
        _unfarm(_wantAmt);

        uint256 wantAmt = IERC20(stakeToken).balanceOf(address(this));
        if (_wantAmt > wantAmt) {
            _wantAmt = wantAmt;
        }
        if (totalStaked < _wantAmt) {
            _wantAmt = totalStaked;
        }
        totalStaked = totalStaked.sub(_wantAmt);
        if (withdrawFeeFactor < withdrawFeeFactorMax) {
            uint256 withdrawFee = _wantAmt.sub(wantAmt.mul(withdrawFeeFactor).div(withdrawFeeFactorMax));
            IERC20(stakeToken).safeTransfer(rewardsAddress, withdrawFee);
            _wantAmt = _wantAmt.sub(withdrawFee);
        }
        IERC20(stakeToken).safeTransfer(kfiFarmAddress, _wantAmt);
        return sharesRemoved;
    }

    // 进行token兑换
    function _safeSwap(
        address _uniRouterAddress,
        uint256 _amountIn,
        uint256 _slippageFactor,
        address[] memory _path,
        address _to,
        uint256 _deadline
    ) internal virtual {
        uint256[] memory amounts = ISwapRouter(_uniRouterAddress).getAmountsOut(_amountIn, _path);
        uint256 amountOut = amounts[amounts.length.sub(1)];
        ISwapRouter(_uniRouterAddress)
        .swapExactTokensForTokensSupportingFeeOnTransferTokens(
            _amountIn,
            amountOut.mul(_slippageFactor).div(1000),
            _path,
            _to,
            _deadline
        );
    }

    //提取收益，兑换为抵押币种，进行复投
    function earn() public virtual whenNotPaused {
        if (onlyGov) {
            require(msg.sender == govAddress, "!gov");
        }

        _unfarm(0);

        if (earnedAddress == woktAddress) {
            _wrapOKT();
        }

        uint256 earnedAmt = IERC20(earnedAddress).balanceOf(address(this));
        if(earnedAmt<=0){
            return;
        }
        uint256 stakeP1 = IPrice(priceAddr).coinPrice(earnedAddress);
        uint256 earnUsd = earnedAmt.mul(stakeP1).div(1e18);
        if(earnUsd <earnLimit){
            return;
        }


        earnedAmt = distributeFees(earnedAmt);
        earnedAmt = buyBack(earnedAmt);

        if(earnedAddress != stakeToken){
            IERC20(earnedAddress).safeApprove(uniRouterAddress, 0);
            IERC20(earnedAddress).safeIncreaseAllowance(
                uniRouterAddress,
                earnedAmt
            );

            if (earnedAddress != stakeToken) {
                _safeSwap(
                    uniRouterAddress,
                    earnedAmt,
                    slippageFactor,
                    earnToStakePath,
                    address(this),
                    block.timestamp.add(600)
                );
            }
        }

        _farm();


    }


    modifier blockPer() {
        uint256 x = block.number.sub(lastBlock);
        if(x>diffBlock){
            uint256 balance = IStrategyFarm(strategyFarmAddr).pendingReward(address(this));
            sencondsReward = balance.div(x).div(3);
            lastStake = totalStaked;
            lastBlock = block.number;
        }
        _;
    }



    function _wrapOKT() internal virtual {
        // OKT -> WOKT
        uint256 oktBal = address(this).balance;
        if (oktBal > 0) {
            IWOKT(woktAddress).deposit{value: oktBal}(); // OKT -> WOKT
        }
    }


    function distributeFees(uint256 _earnedAmt) internal virtual returns (uint256) {
        if (_earnedAmt > 0 && controllerFee > 0) {
            uint256 fee = _earnedAmt.mul(controllerFee).div(controllerFeeMax);
            IERC20(earnedAddress).safeTransfer(rewardsAddress, fee);
            _earnedAmt = _earnedAmt.sub(fee);
        }
        return _earnedAmt;
    }


    function buyBack(uint256 _earnedAmt) internal virtual returns (uint256) {
        if (buyBackRate <= 0) {
            return _earnedAmt;
        }
        uint256 buyBackAmt = _earnedAmt.mul(buyBackRate).div(buyBackRateMax);
        if (earnedAddress == kfiAddress) {
            IERC20(earnedAddress).safeTransfer(buyBackAddress, buyBackAmt);
        } else {
            IERC20(earnedAddress).safeIncreaseAllowance(
                uniRouterAddress,
                buyBackAmt
            );
            if(buyUsdt){
                _safeSwap(
                    uniRouterAddress,
                    buyBackAmt,
                    slippageFactor,
                    earnedToUsdtPath,
                    buyBackAddress,
                    block.timestamp.add(600)
                );
            }else{
                _safeSwap(
                    uniRouterAddress,
                    buyBackAmt,
                    slippageFactor,
                    earnedToKfiPath,
                    buyBackAddress,
                    block.timestamp.add(600)
                );
            }

        }
        return _earnedAmt.sub(buyBackAmt);
    }


    function stakePrice() internal view returns (uint256) {
        return IPrice(priceAddr).coinPrice(stakeToken);
    }

    function tvl() public view returns (uint256) {
        uint256 totalTvl = 0;
        uint256 price = stakePrice();
        totalTvl = totalStaked.mul(price).div(1e18);
        if (ERC20(stakeToken).decimals() == 10) {
            totalTvl = totalTvl.mul(1e8);
        }
        return totalTvl;
    }

    function userTvl(uint256 _userShare) public view returns (uint256) {
        if (totalShared == 0) {
            return 0;
        }
        return _userShare.mul(tvl()).div(totalShared);
    }

    function apyInfo(uint256 _everyBlockReward) public view returns (uint256,uint256) {
        uint256 kfiApy = 0 ;
        uint256 stakePrice = stakePrice();
        uint256 stakeTokenUsd = lastStake.mul(stakePrice).div(1e18);
        if(stakeTokenUsd>0){
            if(_everyBlockReward>0 && stakeTokenUsd >0){
                uint256 p1 = IPrice(priceAddr).coinPrice(kfiAddress);
                kfiApy = p1.mul(31536000).mul(_everyBlockReward).div(stakeTokenUsd);
            }
            uint256 chePrice = IPrice(priceAddr).coinPrice(earnedAddress);
            uint256 apy = sencondsReward.mul(31536000).mul(chePrice).div(stakeTokenUsd);
            return (apy,kfiApy);
        }else{
            return (0,0);
        }

    }


    function poolDataInfo(uint256 _us,address _userAddr) public view
    returns (
        uint256,
        uint256,
        uint256,
        uint256,
        uint256,
        uint256
    )
    {
        uint256 deposit = 0;

        uint256 tvl = tvl();
        if (totalShared > 0 && _us > 0) {
            uint256 userShare = _us;
            deposit = userShare.mul(totalStaked).div(totalShared);
        }

        uint256 tokenPrice = stakePrice();
        uint256 crtFeeRate = controllerFee;
        uint256 maxEnterRate = entranceFeeFactorMax.sub(entranceFeeFactorLL);
        uint256 withdrawFeeRate = withdrawFeeFactorMax.sub(withdrawFeeFactor);

        return (tvl,deposit,tokenPrice,crtFeeRate,maxEnterRate,withdrawFeeRate);
    }


    function pause() public virtual onlyAllowGov {
        _pause();
    }

    function unpause() public virtual onlyAllowGov {
        _unpause();
    }


    function setFeeSettings(
        uint256 _entranceFeeFactor,
        uint256 _withdrawFeeFactor,
        uint256 _controllerFee,
        uint256 _buyBackRate,
        uint256 _slippageFactor
    ) public virtual onlyAllowGov {
        require(_entranceFeeFactor >= entranceFeeFactorLL,"_entranceFeeFactor too low");
        require(_entranceFeeFactor <= entranceFeeFactorMax,"_entranceFeeFactor too high");
        entranceFeeFactor = _entranceFeeFactor;

        require(_withdrawFeeFactor >= withdrawFeeFactorLL,"_withdrawFeeFactor too low");
        require(_withdrawFeeFactor <= withdrawFeeFactorMax,"_withdrawFeeFactor too high");
        withdrawFeeFactor = _withdrawFeeFactor;

        require(_controllerFee <= controllerFeeUL, "_controllerFee too high");
        controllerFee = _controllerFee;

        require(_buyBackRate <= buyBackRateUL, "_buyBackRate too high");
        buyBackRate = _buyBackRate;

        require(_slippageFactor <= slippageFactorUL,"_slippageFactor too high");
        slippageFactor = _slippageFactor;

        emit SetSettings(
            _entranceFeeFactor,
            _withdrawFeeFactor,
            _controllerFee,
            _buyBackRate,
            _slippageFactor
        );
    }

    function setDiffBlock(uint256 _db)public virtual onlyAllowGov{
        diffBlock = _db;
    }


    function setEarnLimit(uint256 _minEarnUsd)public virtual onlyAllowGov{
        earnLimit = _minEarnUsd;
    }

    function setStakeToken(address _stakeToken) public virtual onlyAllowGov {
        stakeToken = _stakeToken;
        emit UpdateAddress(_stakeToken);
    }
    function setUsdtAddr(address _addr)public virtual onlyAllowGov{
        usdtAddr = _addr;
        emit UpdateAddress(_addr);
    }

    function setRewardsAddress(address _rewardsAddress) public virtual onlyAllowGov {
        rewardsAddress = _rewardsAddress;
        emit UpdateAddress(_rewardsAddress);
    }

    function setBuyBackAddress(address _buyBackAddress) public virtual onlyAllowGov {
        buyBackAddress = _buyBackAddress;
        emit UpdateAddress(_buyBackAddress);
    }

    function setStrategyFarmAddr(address _strategyFarmAddr) public virtual onlyAllowGov {
        strategyFarmAddr = _strategyFarmAddr;
        emit UpdateAddress(_strategyFarmAddr);
    }

    function setUniRouterAddress(address _uniRouterAddress) public virtual onlyAllowGov {
        uniRouterAddress = _uniRouterAddress;
        emit UpdateAddress(_uniRouterAddress);
    }

    function setEarnedAddress(address _earnedAddress) public virtual onlyAllowGov {
        earnedAddress = _earnedAddress;
        emit UpdateAddress(_earnedAddress);
    }

    function setKfiAddress(address _kfiAddress) public virtual onlyAllowGov {
        kfiAddress = _kfiAddress;
        emit UpdateAddress(_kfiAddress);
    }

    function setPriceAddrAddress(address _priceAddr) public virtual onlyAllowGov {
        priceAddr = _priceAddr;
        emit UpdateAddress(_priceAddr);
    }

    function setGov(address _govAddress) public virtual onlyAllowGov {
        govAddress = _govAddress;
        emit UpdateAddress(_govAddress);
    }

    function setEarnedToUsdtPath(address[] memory _address) public virtual onlyAllowGov {
        earnedToUsdtPath = _address;
        emit UpdatePath(_address);
    }
    function setEarnedToKfiPath(address[] memory _address) public virtual onlyAllowGov {
        earnedToKfiPath = _address;
        emit UpdatePath(_address);
    }

    function setEarnToStakePath(address[] memory _address) public virtual onlyAllowGov {
        earnToStakePath = _address;
        emit UpdatePath(_address);
    }


    function setOnlyGov(bool _onlyGov) public virtual onlyAllowGov {
        onlyGov = _onlyGov;
        emit SetOnlyGov(_onlyGov);
    }

    function setBuyUsdt(bool _buyUsdt) public virtual onlyAllowGov {
        buyUsdt = _buyUsdt;
        emit SetBuyUsdt(_buyUsdt);
    }

    modifier onlyAllowGov() {
        require(msg.sender == govAddress, "!gov");
        _;
    }

}
