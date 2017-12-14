pragma solidity ^0.4.18;

import './EURToken.sol';

// For the sake of simplicity lets assume EUR is a ERC20 token 
// Also lets assume we can 100% trust the exchange rate oracle 
contract Payroll { 

    EURToken tokenContract;

    uint public month = 30 days;   // Assuming month is 30 days
    uint public year = month * 12; // And year is 12 months
    address public owner;
    
    struct Employee {
        address accountAddress;
        uint salary;            // Yearly salary in EUR tokens
        uint startedWorkingTS;  // TS when employee was hired
        uint endedWorkingTS;    // TS when employee was fired. If less than hired - employee still active
        uint pendingPayment;    // Pending funds employee can withdraw
        uint lastCalculatedTS;  // TS when employees earnings were last added to pendingPayment
    }
    
    Employee[] private employees;
    mapping(address => uint) private employeeIDs;
    mapping(address => bool) private isEmployee;

    //
    // EVENTS - TBD
    //

    modifier onlyOwner() {
        require(msg.sender == owner);
        _;
    }
    
    modifier onlyEmployee(address _address) {
        require(isEmployee[_address]);
        _;
    }
    
    function Payroll(address EURTokenAddress) public {
        owner = msg.sender;
        tokenContract = EURToken(EURTokenAddress);
    }
    
    ////////////////
    /* OWNER ONLY */
    ////////////////
    
    // TODO: Figure out what to do if the employee already worked in the past and was fired
    function addEmployee(
        address _accountAddress,
        uint256 _initialYearlyEURSalary)
        external
        onlyOwner {
        Employee memory newEmployee;
        
        newEmployee.accountAddress = _accountAddress;
        newEmployee.salary = _initialYearlyEURSalary;
        newEmployee.startedWorkingTS = now;        
        
        employeeIDs[_accountAddress] = employees.length;
        isEmployee[_accountAddress] = true;
        employees.push(newEmployee);
    }
    
    function removeEmployee(uint256 employeeId) external
        onlyOwner {
        Employee storage employee = employees[employeeId];
        employee.endedWorkingTS = now;
        uint timeWorked = (employee.endedWorkingTS - employee.startedWorkingTS)/year;
        uint owed = timeWorked * employee.salary;
        employee.pendingPayment += owed;
    }

    //function setEmployeeSalary(uint256 employeeId, uint256 yearlyEURSalary); 
    
    function EscapeHatch() public onlyOwner {
        tokenContract.transfer(owner, tokenContract.balanceOf(address(this)));
    }
    
    // TBD:
    //function depositTokenFunds(); // Use approveAndCall or ERC223 tokenFallback 
    //function withdrawTokenFunds(); // Use approveAndCall or ERC223 tokenFallback 

    ///////////////
    /*  GETTERS  */
    ///////////////
    
    function getEmployeeCount() public view returns (uint256) {
        return employees.length;
    }

    // Return all important info too 
    function getEmployee(uint256 employeeId) public view returns (
        address accountAddress,
        uint salary,
        uint startedWorkingTS,
        uint endedWorkingTS,
        uint pendingPayment,
        uint lastCalculatedTS) {
        assert(employeeId < employees.length);
        Employee storage employee = employees[employeeId];
        return (employee.accountAddress, employee.salary, employee.startedWorkingTS, employee.endedWorkingTS, employee.pendingPayment, employee.lastCalculatedTS);
    }
    
    // Monthly EUR amount spent in salaries 
    function calculatePayrollBurnrate() public view returns (uint256) {
        uint sum;
        for (uint i=0; i<employees.length; i++) {
            sum += employees[i].salary;
        }
        return sum / 12;
    }
    
    // Days until the contract can run out of funds 
    function calculatePayrollRunway() public view returns (uint256) {
        return tokenContract.balanceOf(address(this)) / (calculatePayrollBurnrate()/30);
    }
    
    // Called when something related to employee money changes (salary, fire, payday)
    function recalculatePending(uint employeeId) internal {
        Employee storage employee = employees[employeeId];
        uint endTS = (employee.endedWorkingTS > employee.startedWorkingTS) ? employee.endedWorkingTS : now;
        uint startTS = (employee.lastCalculatedTS > employee.startedWorkingTS) ? employee.lastCalculatedTS : employee.startedWorkingTS;
        employee.lastCalculatedTS = endTS;
        employee.pendingPayment += (endTS - startTS) * employee.salary / year;
    }

    ///////////////////
    /* EMPLOYEE ONLY */
    ///////////////////
    
    // only callable once a month 
    function payday() public onlyEmployee(msg.sender) {
        uint employeeId = employeeIDs[msg.sender];
        recalculatePending(employeeId);
        uint amount = employees[employeeId].pendingPayment;
        
        require(amount > 0); // Has something to withdraw
        require(amount < tokenContract.balanceOf(address(this))); // Contract has enough tokens to pay
        
        employees[employeeIDs[msg.sender]].pendingPayment = 0;
        tokenContract.transfer(msg.sender, amount);
    }

    /* ORACLE ONLY */
    //function setExchangeRate(address token, uint256 EURExchangeRate); // uses decimals from token 
}
