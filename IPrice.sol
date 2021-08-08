pragma solidity 0.6.12;

interface IPrice {

    function coinPrice(address _token)
    external
    view
    returns (uint256);

    function lpPrice(address _lpToken)
    external
    view
    returns (uint256);
}
