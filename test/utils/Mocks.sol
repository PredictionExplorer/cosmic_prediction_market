// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

/// @notice Minimal well-behaved ERC20 standing in for CST. Functions are virtual
/// so adversarial variants below can override them.
contract MockCst {
    string public constant name = "Mock Cosmic Signature Token";
    string public constant symbol = "CST";
    uint8 public constant decimals = 18;

    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function approve(address spender, uint256 amount) external virtual returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transfer(address to, uint256 amount) public virtual returns (bool) {
        return _move(msg.sender, to, amount);
    }

    function transferFrom(address from, address to, uint256 amount) public virtual returns (bool) {
        uint256 allowed = allowance[from][msg.sender];
        if (allowed != type(uint256).max) allowance[from][msg.sender] = allowed - amount;
        return _move(from, to, amount);
    }

    function _move(address from, address to, uint256 amount) internal returns (bool) {
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

/// @dev Mimics the two CosmicSignatureGame getters the market reads. The public
/// mapping generates the same `bidderAddresses(uint256) returns (uint256)` getter
/// as the real contract's mapping-to-struct.
contract MockGame {
    uint256 public roundNum;
    address public token;
    mapping(uint256 => uint256) public bidderAddresses;

    constructor(address token_) {
        token = token_;
    }

    function setRoundNum(uint256 roundNum_) external {
        roundNum = roundNum_;
    }

    function setNumBids(uint256 roundNum_, uint256 numBids) external {
        bidderAddresses[roundNum_] = numBids;
    }
}

interface IReentryHook {
    function onCstReceived() external;
}

/// @notice CST variant that notifies a hook contract whenever it receives tokens,
/// letting adversarial tests attempt reentrancy mid-transfer.
contract ReenteringCst is MockCst {
    address public hook;

    function setHook(address hook_) external {
        hook = hook_;
    }

    function transfer(address to, uint256 amount) public override returns (bool) {
        bool ok = super.transfer(to, amount);
        if (to == hook && hook != address(0)) IReentryHook(hook).onCstReceived();
        return ok;
    }
}

/// @notice CST variant whose transfers return false without moving anything,
/// to verify the market surfaces `TransferFailed` instead of silently continuing.
contract FalseReturningCst is MockCst {
    bool public failTransfers;

    function setFailTransfers(bool fail) external {
        failTransfers = fail;
    }

    function transfer(address to, uint256 amount) public override returns (bool) {
        if (failTransfers) return false;
        return super.transfer(to, amount);
    }

    function transferFrom(address from, address to, uint256 amount) public override returns (bool) {
        if (failTransfers) return false;
        return super.transferFrom(from, to, amount);
    }
}
