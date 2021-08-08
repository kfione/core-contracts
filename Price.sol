pragma solidity 0.6.12;

import "./Ownable.sol";
import "./IKSwapInfo.sol";
import "./ERC20.sol";
import "./IPair.sol";


contract Price is Ownable{

    using SafeMath for uint256;

    event UpdateAddress(address _address);

    address public usdt = address(0x382bB369d343125BfB2117af9c149795C6C65C50);
    address public ksOracle = address(0x5d1F23b1564ce7A00C94f9Fa970D9c630369CA72);
    address public kfi = address(0x451cD5c74bbCfDAf4120C1dE40cbD0E683B1190f);
    address public kfi_usdt_lp = address(0x4F041aE9a9f80eD49201c3E44b0dA000D6FA402e);
    address public che = address(0x8179D97Eb6488860d816e3EcAFE694a4153F216c);
    address public che_usdt_lp = address(0x089dedbFD12F2aD990c55A2F1061b8Ad986bFF88);

    function coinPrice(address  _token) public view returns (uint256) {
        if(IKSwapInfo(ksOracle).isRouterToken(_token)){
            return IKSwapInfo(ksOracle).getCurrentPrice(_token);
        }else if(_token == kfi || _token == che){
            IPair lp;
            if(_token == kfi){
                lp = IPair(kfi_usdt_lp);

            }else if(_token == che){
                lp =  IPair(che_usdt_lp);
            }

            (uint reserve0, uint reserve1, ) = lp.getReserves();
            if(reserve0==0 || reserve1==0){
                return 0;
            }
            address token0 = lp.token0();
            address token1 = lp.token1();
            if(token0 == usdt){
                uint256 token0Decimals = ERC20(token0).decimals();
                uint256 token1Decimals = ERC20(token1).decimals();
                return reserve0.mul(10**18).div(token0Decimals).mul(10**18).div(reserve1.mul(10**18).div(token1Decimals));
            }else if(token1 == usdt){
                uint256 token0Decimals = ERC20(token0).decimals();
                uint256 token1Decimals = ERC20(token1).decimals();
                return reserve1.mul(10**18).div(token1Decimals).mul(10**18).div(reserve0.mul(10**18).div(token0Decimals));

            }else{
                return 0;
            }
        }else{
            return 0;
        }

    }

    function lpPrice(address  _lpToken) public view returns (uint256) {
        if(_lpToken == address(0)) {
            return 0;
        }

        IPair lp = IPair(_lpToken);
        uint256 totalSupply = lp.totalSupply();
        if(totalSupply==0){
            return 0;
        }

        (uint reserve0,uint reserve1 , ) = lp.getReserves();
        if(reserve0 > 0) {
            address token0 = lp.token0();
            address token1 = lp.token1();
            if(IKSwapInfo(ksOracle).isRouterToken(token0)){
                uint256  token0Price = IKSwapInfo(ksOracle).getCurrentPrice(token0);
                uint256 tokenDecimals = ERC20(token0).decimals();
                return token0Price.mul(2).mul(reserve0).mul(10**18).div(totalSupply).div(10**tokenDecimals);
            }else if(IKSwapInfo(ksOracle).isRouterToken(token1)){
                uint256  token1Price = IKSwapInfo(ksOracle).getCurrentPrice(token1);
                uint256 token1Decimals = ERC20(token1).decimals();
                return token1Price.mul(2).mul(reserve1).mul(10**18).div(totalSupply).div(10**token1Decimals);
            }else{
                return 0;
            }

        }else{
            return 0;
        }
    }


    function setUsdtAddress(address _addr) public onlyOwner {
        usdt = _addr;
        emit UpdateAddress(_addr);
    }


    function setKfiAddress(address _addr) public onlyOwner {
        kfi = _addr;
        emit UpdateAddress(_addr);
    }


    function setKfiUsdtLp(address _addr) public onlyOwner {
        kfi_usdt_lp = _addr;
        emit UpdateAddress(_addr);
    }


    function setKsOracle(address _addr) public onlyOwner {
        ksOracle = _addr;
        emit UpdateAddress(_addr);
    }

}
