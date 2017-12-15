pragma solidity ^0.4.18;

import './EURToken.sol';

// For the sake of simplicity lets assume EUR is a ERC20 token 
// Also lets assume we can 100% trust the exchange rate oracle 
contract Payroll { 
    EURToken tokenContract;

    uint public month = 30 days;   // Assuming month is 30 days
    uint public year = month * 12; // And year is 12 months
    uint public paydayFrequency = 1*month; // How frequently an employee can withdraw funds
    
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
    mapping(uint => uint) private lastPaydayCall; // TS when employeeID called Payday last time
    
    function Payroll(address EURTokenAddress) public {
        owner = msg.sender;
        tokenContract = EURToken(EURTokenAddress);
    }

    ////////////
    /* EVENTS */
    ////////////
    
    event LogGotTokens(address indexed addressFrom, uint256 indexed amount, bytes data);
    event LogWithdraw(address indexed addressTo, uint256 indexed amount);
    event LogEmployeeAdded(address indexed accountAddress, uint256 indexed employeeID, uint256 initialYearlyEURSalary);
    event LogEmployeeRemoved(address indexed accountAddress, uint256 indexed employeeID, uint256 moneyOwed);
    event LogSalaryChange(address indexed accountAddress, uint256 indexed employeeID, uint256 yearlyEURSalary);
    event LogPayday(address indexed accountAddress, uint256 indexed employeeID, uint256 amountPaid);
    event LogEscapeHatchUse(address indexed owner, uint256 amount);
    
    ///////////////
    /* MODIFIERS */
    ///////////////

    modifier onlyOwner() {
        require(msg.sender == owner);
        _;
    }
    
    modifier onlyEmployee(address _address) {
        require(isEmployee[_address]);
        _;
    }


    ///////////////
    /* FUNCTIONS */
    ///////////////

    function tokenFallback(address _from, uint _value, bytes _data) external {
        LogGotTokens(_from, _value, _data);
    }
    
    ////////////////
    /* OWNER ONLY */
    ////////////////
    
    // Use approveAndCall or ERC223 tokenFallback 
    function withdrawTokenFunds(uint _value) external onlyOwner {
        tokenContract.transfer(msg.sender, _value);
        LogWithdraw(msg.sender, _value);
    }

    // TODO: Figure out what to do if the employee already worked in the past and was fired
    // TODO: Do we need to check for a duplicate? Or that's the solution for fired past workers?
    function addEmployee(
        address _accountAddress,
        uint256 _initialYearlyEURSalary)
        external
        onlyOwner {
        Employee memory newEmployee;
        
        newEmployee.accountAddress = _accountAddress;
        newEmployee.salary = _initialYearlyEURSalary;
        newEmployee.startedWorkingTS = now;        
        
        uint employeeID = employees.length;
        employeeIDs[_accountAddress] = employeeID;
        isEmployee[_accountAddress] = true;
        employees.push(newEmployee);
        
        lastPaydayCall[employeeID] = newEmployee.startedWorkingTS;
        
        LogEmployeeAdded(_accountAddress, employeeID, _initialYearlyEURSalary);
    }
    
    function removeEmployee(uint256 employeeID) external
        onlyOwner {
        Employee storage employee = employees[employeeID];
        employee.endedWorkingTS = now;
        recalculatePending(employeeID);
        
        lastPaydayCall[employeeID] = now - paydayFrequency; // Allow fired employee to withdraw funds instantly

        LogEmployeeRemoved(employee.accountAddress, employeeID, employee.pendingPayment);
    }

    function setEmployeeSalary(
        uint256 employeeID,
        uint256 newYearlyEURSalary)
        external
        onlyOwner {
        Employee storage employee = employees[employeeID];
        recalculatePending(employeeID);
        employee.salary = newYearlyEURSalary;
        LogSalaryChange(employee.accountAddress, employeeID, newYearlyEURSalary);
    }
    
    function EscapeHatch() external onlyOwner {
        uint amount = tokenContract.balanceOf(address(this));
        tokenContract.transfer(owner, amount);
        LogEscapeHatchUse(owner, amount);
    }
    
    ///////////////
    /*  GETTERS  */
    ///////////////
    
    function getEmployeeCount() public view returns (uint256) {
        return employees.length;
    }

    // Return all important info too 
    function getEmployee(uint256 employeeID) public view returns (
        address accountAddress,
        uint salary,
        uint startedWorkingTS,
        uint endedWorkingTS,
        uint pendingPayment,
        uint lastCalculatedTS) {
        require(employeeID < employees.length);
        Employee storage employee = employees[employeeID];
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
    function recalculatePending(uint employeeID) internal {
        Employee storage employee = employees[employeeID];
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
        uint employeeID = employeeIDs[msg.sender];
        
        require((now - lastPaydayCall[employeeID]) >= paydayFrequency); // Payday can only be called once a (paydayFrequency)
        lastPaydayCall[employeeID] = now;
        
        recalculatePending(employeeID);
        uint amount = employees[employeeID].pendingPayment;
        
        require(amount > 0); // Has something to withdraw
        require(amount < tokenContract.balanceOf(address(this))); // Contract has enough tokens to pay
        
        employees[employeeIDs[msg.sender]].pendingPayment = 0;
        tokenContract.transfer(msg.sender, amount);
        LogPayday(msg.sender, employeeID, amount);
    }

    /* ORACLE ONLY */
    // Assuming EUR is an ERC20 token,
    // I didn't see the need to use an exchange rate oracle,
    // as the salary is already specified in EUR (tokens)
    //function setExchangeRate(address token, uint256 EURExchangeRate); // uses decimals from token 

    //******* For Testing Purposes - Delete afterwards
    function setOwner(address newOwner) external onlyOwner {
        owner = newOwner;
    }

    function getBalance() external view returns (uint) {
        tokenContract.balanceOf(address(this));
    }

}
