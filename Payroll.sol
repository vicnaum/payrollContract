pragma solidity ^0.4.18;

import './EURToken.sol';

// For the sake of simplicity lets assume EUR is a ERC20 token 
//
// Not using SafeMath, because as far as I can see - every possible attack vector comes from the Owner,
// and we assume the Owner is wise, and don't do any checks for incorrect inputs
// (for the purposes of this test)
contract Payroll { 
    EURToken tokenContract;

    uint public periodUnit = 1 days;         // Minimal period unit - default 1 day
//    uint public periodUnit = 1 seconds;        // (or 1 second for testing purposes)
    uint public daysInMonth = 30;              // Default month - 30 days
    uint public monthsInYear = 12;             // Default year - 12 months
    uint public month = daysInMonth * periodUnit;
    uint public year = month * monthsInYear;
    uint public paydayFrequency = 1 * month;     // How frequently an employee can withdraw funds
    
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

    // If someone unintentionally/maliciously sent ETH to the contract - this can withdraw it
    function withdrawEther() external onlyOwner {
        require(address(this).balance > 0);
        msg.sender.transfer(address(this).balance);
    }

    // Adds an employee with specified yearly salary
    //
    // TODO: Currently can add multiple same-address employees.
    //       That's good if you fire and rehire again. But contract pays only the last one.
    //       Maybe needs to check if all previous inclusions were fired?
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
    
    // Fires an employee by ID, and calculates their exit paycheck
    function removeEmployee(uint256 employeeID) external
        onlyOwner {
        Employee storage employee = employees[employeeID];
        require(employee.endedWorkingTS < employee.startedWorkingTS); // Check if employee wasn't already fired
        employee.endedWorkingTS = now;
        recalculatePending(employeeID);
        
        lastPaydayCall[employeeID] = now - paydayFrequency; // Allow fired employee to withdraw funds instantly

        LogEmployeeRemoved(employee.accountAddress, employeeID, employee.pendingPayment);
    }

    // Changes employee ID salary, summing up the earnings before the change occured
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
    
    // Emergency withdrawal of all tokens owned by contract
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
            if (employees[i].endedWorkingTS < employees[i].startedWorkingTS) { // Check if employee wasn't fired
                sum += employees[i].salary;
            }
        }
        return sum / monthsInYear;
    }
    
    // Days until the contract can run out of funds 
    //
    // TODO: Take into account current employees pending Payments
    function calculatePayrollRunway() public view returns (uint256) {
        return tokenContract.balanceOf(address(this)) / (calculatePayrollBurnrate()/daysInMonth);
    }
    
    // Called before something related to employee money is about to change (new salary, fire, payday)
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
    
    // only callable once a period (month)
    function payday() public onlyEmployee(msg.sender) {
        uint employeeID = employeeIDs[msg.sender];
        
        require((now - lastPaydayCall[employeeID]) >= paydayFrequency); // Payday can only be called once a (paydayFrequency)
        lastPaydayCall[employeeID] = now;
        
        recalculatePending(employeeID);
        uint amount = employees[employeeID].pendingPayment;
        
        require(amount > 0); // Has something to withdraw
        uint contractBalance = tokenContract.balanceOf(address(this));
        
        if (amount < contractBalance) { // If contract has enough funds to pay - then just pay
            employees[employeeIDs[msg.sender]].pendingPayment = 0;
            tokenContract.transfer(msg.sender, amount);
            LogPayday(msg.sender, employeeID, amount);            
        } else {  // If not - pay what we have, and leave the rest in pending
            uint pending = amount - contractBalance;
            amount = contractBalance;
            
            employees[employeeIDs[msg.sender]].pendingPayment = pending;
            lastPaydayCall[employeeID] = now - paydayFrequency; // Allow employee to withdraw rest of pending funds instantly
            
            tokenContract.transfer(msg.sender, amount);
            LogPayday(msg.sender, employeeID, amount);
        } 
        
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
