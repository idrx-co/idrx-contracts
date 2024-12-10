// SPDX-License-Identifier: MIT
pragma solidity ^0.8.9;

import "./IDRXBasicToken.sol";
import "./ERC20BurnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/security/PausableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";

contract IDRX is Initializable, IDRXBasicToken, ERC20BurnableUpgradeable, PausableUpgradeable, UUPSUpgradeable, AccessControlUpgradeable {
    bytes32 public constant PAUSER_ROLE = keccak256("PAUSER_ROLE");
    bytes32 public constant MINTER_ROLE = keccak256("MINTER_ROLE");
    bytes32 public constant UPGRADER_ROLE = keccak256("UPGRADER_ROLE");
    bytes32 public constant BLACKLIST_ROLE = keccak256("BLACKLIST_ROLE");
    mapping (address => bool) public isBlackListed;
    uint256 public _bridgeNonce;
    uint64 burnBridgeFee;
    uint64 mintBridgeFee;
    address platformFeeRecipient;
    // sourceChainId => sourceChainNonce
    mapping (uint => mapping(uint => bool)) public fromChainNonceUsed;

    bytes32 public constant PLATFORM_FEE_SETTER_ROLE = keccak256("PLATFORM_FEE_SETTER_ROLE");

    uint64 public constant maxPlatformFee = 1000000;

    event DestroyedBlackFunds(address _blackListedUser, uint _balance);

    event AddedBlackList(address _user);

    event RemovedBlackList(address _user);

    event BurnWithAccountNumber(address _user, uint256 amount, string hashedAccountNumber);

    event BurnBridge(address _user, uint256 _amount, uint amountAfterCut, uint toChain, uint256 _bridgeNonce, uint256 platformFee);

    event MintBridge(address _user, uint256 _amount, uint amountAfterCut, uint fromChain, uint256 fromBridgeNonce, uint256 platformFee);

    event PlatformFeeInfoUpdated(address _platformFeeRecipient, uint64 _burnBridgeFee, uint64 _mintBridgeFee);

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize() initializer public {
        __ERC20_init("IDRX", "IDRX");
        __ERC20Burnable_init();
        __Pausable_init();
        __AccessControl_init();
        __UUPSUpgradeable_init();

        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(PAUSER_ROLE, msg.sender);
        _grantRole(MINTER_ROLE, msg.sender);
        _grantRole(UPGRADER_ROLE, msg.sender);
        _grantRole(BLACKLIST_ROLE, msg.sender);
    }

    function pause() public onlyRole(PAUSER_ROLE) {
        _pause();
    }

    function unpause() public onlyRole(PAUSER_ROLE)  {
        _unpause();
    }

    function mint(address to, uint256 amount) public onlyRole(MINTER_ROLE) {
        _mint(to, amount);
    }

    function mintBridge(address to, uint256 amount, uint fromChain, uint fromChainBridgeNonce) public onlyRole(MINTER_ROLE) {        
        require(fromChainNonceUsed[fromChain][fromChainBridgeNonce] == false, 'nonce already used');
        require(amount >= mintBridgeFee, 'not enough token');
        require(platformFeeRecipient != address(0), 'platform fee recipient has not been set');

        uint256 amountAfterCut = amount - mintBridgeFee;

        _mint(to, amountAfterCut);
        _mint(platformFeeRecipient, mintBridgeFee);

        emit MintBridge(to, amount, amountAfterCut, fromChain, fromChainBridgeNonce, mintBridgeFee);
        fromChainNonceUsed[fromChain][fromChainBridgeNonce] = true;
    }

    function burnWithAccountNumber(uint256 amount, string memory accountNumber) public virtual {
        _burn(_msgSender(), amount);

        emit BurnWithAccountNumber(_msgSender(), amount, accountNumber);
    }

    function incrementNonce() private {
        _bridgeNonce = _bridgeNonce + 1;
    }

    function burnBridge(uint256 amount, uint toChain) public virtual {
        require(amount >= burnBridgeFee, 'not enough token');
        require(platformFeeRecipient != address(0), 'platform fee recipient has not been set');

        uint256 amountAfterCut = payoutPlatformFee(burnBridgeFee, amount);
        _burn(_msgSender(), amountAfterCut);

        emit BurnBridge(_msgSender(), amount, amountAfterCut, toChain, _bridgeNonce, burnBridgeFee);
        incrementNonce();
    }

    function _beforeTokenTransfer(address from, address to, uint256 amount)
        internal
        whenNotPaused
        override
    {
        require(!isBlackListed[msg.sender], "Blacklist: account is blacklisted");
        super._beforeTokenTransfer(from, to, amount);
    }

    function _authorizeUpgrade(address newImplementation)
        internal
        onlyRole(UPGRADER_ROLE)
        override
    {}

    function getBlackListStatus(address _maker) external view returns (bool) {
        return isBlackListed[_maker];
    }
    
    function addBlackList (address _evilUser) public onlyRole(BLACKLIST_ROLE) {
         require(_evilUser != address(0), 'zero address cannot be blacklisted');
        isBlackListed[_evilUser] = true;
        emit AddedBlackList(_evilUser);
    }

    function removeBlackList (address _clearedUser) public onlyRole(BLACKLIST_ROLE) {
        isBlackListed[_clearedUser] = false;
        emit RemovedBlackList(_clearedUser);
    }

    function destroyBlackFunds (address _blackListedUser) public onlyRole(BLACKLIST_ROLE) {
        require(isBlackListed[_blackListedUser]);
        uint dirtyFunds = balanceOf(_blackListedUser);
        _balances[_blackListedUser] = 0;
        _totalSupply -= dirtyFunds;
        emit DestroyedBlackFunds(_blackListedUser, dirtyFunds);
    }

    function setPlatformFeeInfo(
        address _platformFeeRecipient,
        uint64 _burnBridgeFee,
        uint64 _mintBridgeFee
    ) external onlyRole(PLATFORM_FEE_SETTER_ROLE) {
        require(_platformFeeRecipient != address(0), 'platform fee recipient has not been set');
        require(_burnBridgeFee <= maxPlatformFee, 'platform fee exceeds maximum amount');
        require(_mintBridgeFee <= maxPlatformFee, 'platform fee exceeds maximum amount');

        burnBridgeFee = _burnBridgeFee;
        mintBridgeFee = _mintBridgeFee;
        platformFeeRecipient = _platformFeeRecipient;

        emit PlatformFeeInfoUpdated(_platformFeeRecipient, _burnBridgeFee, _mintBridgeFee);
    }

    function getPlatformFeeInfo() external view returns (address, uint64, uint64) {
        return (platformFeeRecipient, burnBridgeFee, mintBridgeFee);
    }

    function payoutPlatformFee(
        uint64 platformFee,
        uint256 _totalPayoutAmount
    ) internal returns (uint256){
        uint256 amountAfterCut = _totalPayoutAmount - platformFee;
        transfer(platformFeeRecipient, platformFee);

        return amountAfterCut;
    }

    function approve(address spender, uint256 amount) public virtual override returns (bool) {
        require(!isBlackListed[msg.sender], "Blacklist: account is blacklisted");
        address owner = _msgSender();
        _approve(owner, spender, amount);
        return true;
    }   
}


