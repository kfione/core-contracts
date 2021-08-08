pragma solidity 0.6.12;

interface IStrategyFarm {

    // Info of each pool.
    struct PoolInfo {
        IBEP20 lpToken;           // Address of LP token contract.
        uint256 allocPoint;       // How many allocation points assigned to this pool. CHEs to distribute per block.
        uint256 lastRewardBlock;  // Last block number that CHEs distribution occurs.
        uint256 accChePerShare; // Accumulated CHEs per share, times 1e12. See below.
    }

    // Deposit LP tokens to MasterChef for CAKE allocation.
    function deposit(uint256 _pid, uint256 _amount) external;

    // Withdraw LP tokens from MasterChef.
    function withdraw(uint256 _pid, uint256 _amount) external;

    // Withdraw without caring about rewards. EMERGENCY ONLY.
    function emergencyWithdraw(uint256 _pid) external;


    function deposit(uint256 _amount) external;


    function withdraw(uint256 _amount) external;


    function emergencyWithdraw() external;

    function rewardPerBlock() external view returns (uint256);


    function poolInfo(uint256 _pid) external view returns (PoolInfo);

    function pendingCherry(uint256 _pid, address _user) external view returns (uint256);

    function pendingReward(address _user) external view returns (uint256);


}
