pragma solidity 0.6.12;

interface IKSwapInfo {
    function getCurrentPrice(address token) external view returns (uint256);

    function isRouterToken(address _token) external view returns (bool);

}
