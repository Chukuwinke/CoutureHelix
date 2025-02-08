// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts-upgradeable/utils/ContextUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import "../interfaces/ICustomToken.sol";
import "hardhat/console.sol";

contract CustomERC2771ForwarderUpgradeable is 
    Initializable, 
    UUPSUpgradeable, 
    ContextUpgradeable, 
    ReentrancyGuardUpgradeable 
{
    using ECDSA for bytes32;

    address private _trustedForwarder;
    address private _admin;
    address public tokenAddress;
    uint256 public burnPercentage;
    uint256 private constant SCALE = 10_000;

    mapping(address => uint256) private _nonces;

    event DebugProcess(uint256 gasCostInMatic, uint256 reimbursementInTokens, uint256 burnAmount, uint256 totalCost);

    function initialize(
        address admin,
        address trustedForwarder,
        uint256 _burnPercentage
    ) public initializer {
        __UUPSUpgradeable_init();
        __ReentrancyGuard_init();
        __Context_init();
        _admin = admin;
        _trustedForwarder = trustedForwarder == address(0) ? address(this) : trustedForwarder;
        burnPercentage = _burnPercentage;
    }

    modifier onlyAdmin() {
        require(msg.sender == _admin, "Caller is not admin");
        _;
    }

    function GetTrustedForwarder() public view returns (address) {
        return _trustedForwarder;
    }

    function isTrustedForwarder(address forwarder) public view returns (bool) {
        return forwarder == _trustedForwarder;
    }

    function _msgSender() internal view override returns (address) {
        if (isTrustedForwarder(msg.sender) && msg.data.length >= 20) {
            return address(bytes20(msg.data[msg.data.length - 20:]));
        }
        return super._msgSender();
    }

    function _msgData() internal view override returns (bytes calldata) {
        if (isTrustedForwarder(msg.sender) && msg.data.length >= 20) {
            return msg.data[:msg.data.length - 20];
        }
        return super._msgData();
    }

    function _authorizeUpgrade(address newImplementation) internal override onlyAdmin {}

    function setTokenAddress(address newTokenAddress) external onlyAdmin {
        require(newTokenAddress != address(0), "Token address cannot be zero");
        tokenAddress = newTokenAddress;
    }

    function setBurnPercentage(uint256 newBurnPercentage) external onlyAdmin {
        require(newBurnPercentage <= SCALE, "Burn percentage out of range");
        burnPercentage = newBurnPercentage;
    }

    function setTrustedforwarder(address newForwarder) external onlyAdmin{
        require(newForwarder != address(0), "forwarder address cannot be zero");
        _trustedForwarder = newForwarder;
    }

    function processTransaction(
        bytes calldata req,
        bytes calldata signature,
        uint256 gasUsed,
        uint256 gasPriceInMatic,
        uint256 tokenToMaticRate
    ) external nonReentrant {
        (uint256 chainId, address from, address to, uint256 value, uint256 nonce, bytes memory data) = abi.decode(
            req,
            (uint256, address, address, uint256, uint256, bytes)
        );

        bytes32 hash = keccak256(abi.encode(chainId, from, to, value, nonce, data));
        bytes32 ethSignedHash = MessageHashUtils.toEthSignedMessageHash(hash);
        address recoveredSigner = ECDSA.recover(ethSignedHash, signature);
        require(recoveredSigner == from, "Invalid signature");
        require(nonce == _nonces[from], "Invalid nonce");

        uint256 gasCostInMatic = gasUsed * gasPriceInMatic;
        uint256 reimbursementInTokens = (gasCostInMatic * 1e18) / tokenToMaticRate;
        uint256 burnAmount = (reimbursementInTokens * burnPercentage) / SCALE;
        uint256 totalCost = reimbursementInTokens + burnAmount;

        require(ICustomToken(tokenAddress).transferFrom(from, address(this), totalCost), "Token transfer failed");

        if (burnAmount > 0) {
            ICustomToken(tokenAddress).burn(burnAmount);
        }

        (bool success, ) = to.call{value: value}(abi.encodePacked(data, from));
        require(success, "Transaction execution failed");

        _nonces[from]++;
    }

    function getNonce(address account) public view returns (uint256) {
        return _nonces[account];
    }

    function changeAdmin(address newAdmin) external onlyAdmin {
        require(newAdmin != address(0), "New admin cannot be zero address");
        _admin = newAdmin;
    }
}


/**
pragma solidity ^0.8.20;

import "@openzeppelin/contracts-upgradeable/metatx/ERC2771ForwarderUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import "../interfaces/ICustomToken.sol"; // Import the token interface
import "hardhat/console.sol";


contract CustomERC2771ForwarderUpgradeable is Initializable, UUPSUpgradeable, ERC2771ForwarderUpgradeable, ReentrancyGuardUpgradeable {
    using ECDSA for bytes32;

    address private _admin;
    address public tokenAddress;
    uint256 public burnPercentage; // e.g., 5% = 500 (scaled by 10,000)
    uint256 private constant SCALE = 10_000;

    mapping(address => uint256) private _nonces;

    event DebugMetaTransaction(
        bytes32 indexed hash,
        bytes32 indexed ethSignedHash,
        address indexed recoveredSigner,
        address expectedSigner,
        uint256 nonce,
        uint256 expectedNonce
    );
    event DebugHash(bytes32 hash, bytes32 ethSignedHash, address recoveredSigner);
    event DebugProcess(uint256 gasCostInMatic, uint256 reimbursementInTokens, uint256 burnAmount, uint256 totalCost);
    event DebugVerify(bytes32 hash, bytes32 ethSignedHash, address recoveredSigner, address expectedSigner, uint256 nonce, uint256 expectedNonce);


    event AdminChanged(address indexed oldAdmin, address indexed newAdmin);
    event TokenAddressUpdated(address indexed oldToken, address indexed newToken);
    event BurnPercentageUpdated(uint256 oldPercentage, uint256 newPercentage);
    event MetaTransactionProcessed(address indexed from, address indexed to, uint256 value, uint256 gasUsed, uint256 burnAmount);

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(address admin, uint256 _burnPercentage) public initializer {
        __UUPSUpgradeable_init();
        __ReentrancyGuard_init();

        require(admin != address(0), "Admin address cannot be zero");
        require(_burnPercentage <= SCALE, "Burn percentage out of range");

        _admin = admin;
        burnPercentage = _burnPercentage;
    }

    modifier onlyAdmin() {
        require(msg.sender == _admin, "Caller is not admin");
        _;
    }

    function _authorizeUpgrade(address newImplementation) internal override onlyAdmin {}

    function getNonce(address account) public view returns (uint256) {
        return _nonces[account];
    }

    function _incrementNonce(address account) internal {
        _nonces[account]++;
    }

    function setTokenAddress(address newTokenAddress) external onlyAdmin {
        require(newTokenAddress != address(0), "Token address cannot be zero");
        emit TokenAddressUpdated(tokenAddress, newTokenAddress);
        tokenAddress = newTokenAddress;
    }

    function setBurnPercentage(uint256 newBurnPercentage) external onlyAdmin {
        require(newBurnPercentage <= SCALE, "Burn percentage out of range");
        emit BurnPercentageUpdated(burnPercentage, newBurnPercentage);
        burnPercentage = newBurnPercentage;
    }

    function processTransaction(
        bytes calldata req,
        bytes calldata signature,
        uint256 gasUsed,
        uint256 gasPriceInMatic,
        uint256 tokenToMaticRate
    ) external nonReentrant {
        //console.log("Processing transaction");
        //console.log("Gas used:", gasUsed);
        //console.log("Gas price in Matic:", gasPriceInMatic);
        //console.log("Token to Matic rate:", tokenToMaticRate);
        //console.log("Token address:", tokenAddress);

        console.log("reached 1");
        // Verify meta-transaction
        _verifyMetaTransaction(req, signature);
        console.log("transaction verified");

        console.log("reached 2");
        // Decode the request data
        (uint256 chainId, address from, address to, uint256 value, uint256 nonce, bytes memory data) = abi.decode(
            req,
            (uint256, address, address, uint256, uint256, bytes)
        );
        console.log("reached 3");
        uint256 gasCostInMatic = gasUsed * gasPriceInMatic;

        // Ensure tokenToMaticRate is non-zero to prevent division by zero
        require(tokenToMaticRate > 0, "Invalid token-to-MATIC rate");

        uint256 reimbursementInTokens = (gasCostInMatic * 1e18) / tokenToMaticRate;

        uint256 burnAmount = (reimbursementInTokens * burnPercentage) / SCALE;
        uint256 totalCost = reimbursementInTokens + burnAmount;

        emit DebugProcess(gasCostInMatic, reimbursementInTokens, burnAmount, totalCost);
        console.log("reached 4");

        console.logBytes(data);

        console.log("from:", from);
        console.log("to (forwarder):", address(this));
        console.log("totalCost:", totalCost);
        console.log("burn amount", burnAmount);
        console.log("Allowance:", ICustomToken(tokenAddress).allowance(from, address(this)));
        console.log("Balance of from:", ICustomToken(tokenAddress).balanceOf(from));
        
        // Transfer the total cost from the user
        require(ICustomToken(tokenAddress).transferFrom(from, address(this), totalCost), "Token transfer failed");
        console.log("Forwarder Token Balance:", ICustomToken(tokenAddress).balanceOf(address(this)));

        //console.log("reached 5");
        // Burn the specified portion, if burnPercentage > 0
        if (burnAmount > 0) {
            ICustomToken(tokenAddress).burn(burnAmount);
        }

        // Forward the transaction
        (bool success,) = to.call{value: value, gas: 50000}(data);
        require(success, "Transaction execution failed");

        // Increment nonce
        _incrementNonce(from);

        // Emit transaction event
        emit MetaTransactionProcessed(from, to, value, gasUsed, burnAmount);
    }

    function _verifyMetaTransaction(bytes calldata req, bytes calldata signature) internal view  {
        // Decode meta-transaction request
        (uint256 chainId, address from, address to, uint256 value, uint256 nonce, bytes memory data) = abi.decode(
            req,
            (uint256, address, address, uint256, uint256, bytes)
        );
        // where the problem starts

        bytes32 hash = keccak256(abi.encode(chainId, from, to, value, nonce, data));

        // important MessageHashUtils.toEthSignedMessageHash already adds a prefix to the hash so no need to pass a prefixed hash to it
        bytes32 ethSignedHash = MessageHashUtils.toEthSignedMessageHash(hash);

        // important 
        address recoveredSigner = ECDSA.recover(ethSignedHash, signature);

        


        console.log("Recovered signer:", recoveredSigner);
        console.log("Expected signer (From):", from);

        require(recoveredSigner == from, "Meta-transaction: Invalid signature");
        require(nonce == getNonce(from), "Meta-transaction: Invalid nonce");
    }
    

    function getAdmin() external view returns (address) {
        return _admin;
    }

    function changeAdmin(address newAdmin) external onlyAdmin {
        require(newAdmin != address(0), "New admin cannot be zero address");
        emit AdminChanged(_admin, newAdmin);
        _admin = newAdmin;
    }
}


 */

 

/**
import "@openzeppelin/contracts-upgradeable/metatx/ERC2771ForwarderUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import "../interfaces/ICustomToken.sol"; // Import the token interface
import "hardhat/console.sol";


contract CustomERC2771ForwarderUpgradeable is Initializable, UUPSUpgradeable, ERC2771ForwarderUpgradeable, ReentrancyGuardUpgradeable {
    using ECDSA for bytes32;

    address private _admin;
    address public tokenAddress;
    uint256 public burnPercentage; // e.g., 5% = 500 (scaled by 10,000)
    uint256 private constant SCALE = 10_000;

    mapping(address => uint256) private _nonces;

    event DebugMetaTransaction(
        bytes32 indexed hash,
        bytes32 indexed ethSignedHash,
        address indexed recoveredSigner,
        address expectedSigner,
        uint256 nonce,
        uint256 expectedNonce
    );
    event DebugHash(bytes32 hash, bytes32 ethSignedHash, address recoveredSigner);
    event DebugProcess(uint256 gasCostInMatic, uint256 reimbursementInTokens, uint256 burnAmount, uint256 totalCost);
    event DebugVerify(bytes32 hash, bytes32 ethSignedHash, address recoveredSigner, address expectedSigner, uint256 nonce, uint256 expectedNonce);


    event AdminChanged(address indexed oldAdmin, address indexed newAdmin);
    event TokenAddressUpdated(address indexed oldToken, address indexed newToken);
    event BurnPercentageUpdated(uint256 oldPercentage, uint256 newPercentage);
    event MetaTransactionProcessed(address indexed from, address indexed to, uint256 value, uint256 gasUsed, uint256 burnAmount);

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(address admin, uint256 _burnPercentage) public initializer {
        __UUPSUpgradeable_init();
        __ReentrancyGuard_init();

        require(admin != address(0), "Admin address cannot be zero");
        require(_burnPercentage <= SCALE, "Burn percentage out of range");

        _admin = admin;
        burnPercentage = _burnPercentage;
    }

    modifier onlyAdmin() {
        require(msg.sender == _admin, "Caller is not admin");
        _;
    }

    function _authorizeUpgrade(address newImplementation) internal override onlyAdmin {}

    function getNonce(address account) public view returns (uint256) {
        return _nonces[account];
    }

    function _incrementNonce(address account) internal {
        _nonces[account]++;
    }

    function setTokenAddress(address newTokenAddress) external onlyAdmin {
        require(newTokenAddress != address(0), "Token address cannot be zero");
        emit TokenAddressUpdated(tokenAddress, newTokenAddress);
        tokenAddress = newTokenAddress;
    }

    function setBurnPercentage(uint256 newBurnPercentage) external onlyAdmin {
        require(newBurnPercentage <= SCALE, "Burn percentage out of range");
        emit BurnPercentageUpdated(burnPercentage, newBurnPercentage);
        burnPercentage = newBurnPercentage;
    }

    function processTransaction(
        bytes calldata req,
        bytes calldata signature,
        uint256 gasUsed,
        uint256 gasPriceInMatic,
        uint256 tokenToMaticRate
    ) external nonReentrant {
        //console.log("Processing transaction");
        //console.log("Gas used:", gasUsed);
        //console.log("Gas price in Matic:", gasPriceInMatic);
        //console.log("Token to Matic rate:", tokenToMaticRate);
        //console.log("Token address:", tokenAddress);

        console.log("reached 1");
        // Verify meta-transaction
        _verifyMetaTransaction(req, signature);
        console.log("transaction verified");

        console.log("reached 2");
        // Decode the request data
        (uint256 chainId, address from, address to, uint256 value, uint256 nonce, bytes memory data) = abi.decode(
            req,
            (uint256, address, address, uint256, uint256, bytes)
        );
        console.log("reached 3");
        uint256 gasCostInMatic = gasUsed * gasPriceInMatic;

        // Ensure tokenToMaticRate is non-zero to prevent division by zero
        require(tokenToMaticRate > 0, "Invalid token-to-MATIC rate");

        uint256 reimbursementInTokens = (gasCostInMatic * 1e18) / tokenToMaticRate;

        uint256 burnAmount = (reimbursementInTokens * burnPercentage) / SCALE;
        uint256 totalCost = reimbursementInTokens + burnAmount;

        emit DebugProcess(gasCostInMatic, reimbursementInTokens, burnAmount, totalCost);
        console.log("reached 4");
        // Transfer the total cost from the user
        require(ICustomToken(tokenAddress).transferFrom(from, address(this), totalCost), "Token transfer failed");
        console.log("reached 5");
        // Burn the specified portion, if burnPercentage > 0
        if (burnAmount > 0) {
            ICustomToken(tokenAddress).burn(burnAmount);
        }

        // Forward the transaction
        (bool success,) = to.call{value: value, gas: 50000}(data);
        require(success, "Transaction execution failed");

        // Increment nonce
        _incrementNonce(from);

        // Emit transaction event
        emit MetaTransactionProcessed(from, to, value, gasUsed, burnAmount);
    }

    function _verifyMetaTransaction(bytes calldata req, bytes calldata signature) internal  {
        // Decode meta-transaction request
        (uint256 chainId, address from, address to, uint256 value, uint256 nonce, bytes memory data) = abi.decode(
            req,
            (uint256, address, address, uint256, uint256, bytes)
        );
        // where the problem starts

        bytes32 hash = keccak256(abi.encode(chainId, from, to, value, nonce, data));
        
        // Convert the bytes32 hash to a string for logging
        //string memory hashString = toHexString(hash);
        

        // Log the hash
        //console.log("s-hash:", hashString);



        bytes32 ethSignedHash = MessageHashUtils.toEthSignedMessageHash(hash);
        
        console.log("prefixed hash in contract below");
        //string memory prefixedHashString = toHexString(ethSignedHash);
        console.logBytes32(ethSignedHash);
        //console.log("prefixed hash in solidity contract:", prefixedHashString);
        console.log("signature log raw in contract below");
        console.logBytes(signature);
        //console.log("Reached signature decoding");
        bytes32 r;
        bytes32 s;
        uint8 v;

        // Use `calldatacopy` to read the signature from calldata
        assembly {
            // Load `r` (first 32 bytes of signature)
            r := calldataload(add(signature.offset, 0x00))
            // Load `s` (next 32 bytes of signature)
            s := calldataload(add(signature.offset, 0x20))
            // Load `v` (last byte of signature) and mask to a single byte
            v := byte(0, calldataload(add(signature.offset, 0x40)))
        }
        address manualRecovered = ecrecover(hash, v, r, s);

        // Log the components for debugging
        console.log("decoded signature using asseble in contract below");
        console.logBytes32(r);
        console.logBytes32(s);
        console.logUint(v);
        console.log("address recovered manually : ", manualRecovered);

        address recoveredSigner = ECDSA.recover(ethSignedHash, signature);

        


        console.log("Recovered signer:", recoveredSigner);
        console.log("Expected signer (From):", from);

        emit DebugVerify(hash, ethSignedHash, recoveredSigner, from, nonce, getNonce(from));

        require(recoveredSigner == from, "Meta-transaction: Invalid signature");
        require(nonce == getNonce(from), "Meta-transaction: Invalid nonce");
    }
    // Helper function to convert bytes32 to hex string
    function toHexString(bytes32 data) internal pure returns (string memory) {
        bytes memory alphabet = "0123456789abcdef";
        bytes memory str = new bytes(64);
        for (uint256 i = 0; i < 32; i++) {
            str[i * 2] = alphabet[uint8(data[i] >> 4)];
            str[1 + i * 2] = alphabet[uint8(data[i] & 0x0f)];
        }
        return string(str);
    }

    // Helper function to convert bytes to a hexadecimal string
    function toHexStringM(bytes memory data) internal pure returns (string memory) {
        bytes memory alphabet = "0123456789abcdef";
        bytes memory str = new bytes(2 + data.length * 2);
        str[0] = "0";
        str[1] = "x";
        for (uint256 i = 0; i < data.length; i++) {
            str[2 + i * 2] = alphabet[uint8(data[i] >> 4)];
            str[3 + i * 2] = alphabet[uint8(data[i] & 0x0f)];
        }
        return string(str);
    }

    function getAdmin() external view returns (address) {
        return _admin;
    }

    function changeAdmin(address newAdmin) external onlyAdmin {
        require(newAdmin != address(0), "New admin cannot be zero address");
        emit AdminChanged(_admin, newAdmin);
        _admin = newAdmin;
    }
}

 */

// import "@openzeppelin/contracts-upgradeable/metatx/ERC2771ForwarderUpgradeable.sol";
// import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
// import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";


// contract CustomERC2771ForwarderUpgradeable is Initializable, UUPSUpgradeable, ERC2771ForwarderUpgradeable {
//     address private _admin;
//     mapping(address => uint256) private _nonces;

//     event AdminChanged(address indexed oldAdmin, address indexed newAdmin);

//     /// @custom:oz-upgrades-unsafe-allow constructor
//     constructor() {
//         _disableInitializers(); // Prevent direct usage without initialization
//     }

//     function initialize(address admin) public initializer {
//         __UUPSUpgradeable_init();

//         require(admin != address(0), "Admin address cannot be zero");
//         _admin = admin;
//     }

//     function getNonce(address account) public view returns (uint256) {
//         return _nonces[account];
//     }

//     function incrementNonce(address account) internal {
//         _nonces[account]++;
//     }

//     function testIncrementNonce(address account) external onlyAdmin {
//         incrementNonce(account);
//     }


//     /**
//      * @dev Ensures only the admin can perform upgrades.
//      */
//     function _authorizeUpgrade(address newImplementation) internal override onlyAdmin {}

//     modifier onlyAdmin() {
//         require(msg.sender == _admin, "Caller is not admin");
//         _;
//     }

//     /**
//      * @dev Allows the admin to change the admin address.
//      */
//     function changeAdmin(address newAdmin) external onlyAdmin {
//         require(newAdmin != address(0), "New admin address cannot be zero");
//         emit AdminChanged(_admin, newAdmin);
//         _admin = newAdmin;
//     }

//     /**
//      * @dev Returns the current admin address.
//      */
//     function getAdmin() external view returns (address) {
//         return _admin;
//     }
// }

