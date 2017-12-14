pragma solidity ^0.4.18;

import './EURToken.sol';
import './Payroll.sol'

contract Init {

    uint internal totalSupply = 100000000;
    EURToken public tokenContract;
    Payroll public payrollContract;
    address owner;
    
    function Init() public {
        tokenContract = new EURToken(totalSupply, "EURToken", "EUR", 2);
        payrollContract = new Payroll(address(tokenContract));
        owner = msg.sender;
    }

    function transferFundsToOwner() public {
        tokenContract.transfer(owner, totalSupply);
    }
    
    function getBalance(address addr) public view returns (uint) {
        return tokenContract.balanceOf(addr);
    }
    
    function getMyBalance() public view returns (uint) {
        return tokenContract.balanceOf(msg.sender);
    }
    
}
