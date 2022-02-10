// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.0;

// Base
import "@openzeppelin/contracts-upgradeable/token/ERC1155/ERC1155Upgradeable.sol";

// Token interfaces
import "@openzeppelin/contracts/token/ERC1155/IERC1155.sol";
import "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

// Access Control + security
import "@openzeppelin/contracts-upgradeable/access/AccessControlEnumerableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/security/ReentrancyGuardUpgradeable.sol";

// Utils
import "./openzeppelin-presets/utils/MulticallUpgradeable.sol";

// Meta transactions
import "@openzeppelin/contracts-upgradeable/metatx/ERC2771ContextUpgradeable.sol";

// Helpers
import "@openzeppelin/contracts/interfaces/IERC2981.sol";
import "./lib/CurrencyTransferLib.sol";

/**
 *      - Wrap multiple ERC721 and ERC20 tokens into 'n' shares (i.e. variable supply of 1 ERC 1155 token)
 */

contract Multiwrap is
    ReentrancyGuardUpgradeable,
    ERC2771ContextUpgradeable,
    MulticallUpgradeable,
    AccessControlEnumerableUpgradeable,
    ERC1155Upgradeable 
{
    bytes32 private constant MODULE_TYPE = bytes32("Multiwrap");
    uint256 private constant VERSION = 1;

    /// @dev Only TRANSFER_ROLE holders can have tokens transferred from or to them, during restricted transfers.
    bytes32 private constant TRANSFER_ROLE = keccak256("TRANSFER_ROLE");
    /// @dev Only MINTER_ROLE holders can sign off on `MintRequest`s.
    bytes32 private constant MINTER_ROLE = keccak256("MINTER_ROLE");

    // Token name
    string public name;

    // Token symbol
    string public symbol;

    /// @dev Owner of the contract (purpose: OpenSea compatibility, etc.)
    address private _owner;

    /// @dev The next token ID of the NFT to mint.
    uint256 public nextTokenIdToMint;

    /// @dev The recipient of who gets the royalty.
    address public royaltyRecipient;

    /// @dev The percentage of royalty how much royalty in basis points.
    uint128 public royaltyBps;

    /// @dev Max bps in the thirdweb system
    uint128 private constant MAX_BPS = 10_000;

    /// @dev Whether transfers on tokens are restricted.
    bool public isTransferRestricted;

    /// @dev Contract level metadata.
    string public contractURI;

    /// @dev Token ID => total circulating supply of tokens with that ID.
    mapping(uint256 => uint256) public totalSupply;

    /// @dev Mapping from tokenId => uri for tokenId
    mapping(uint256 => string) private uriForShares;

    /// @dev Mapping from tokenId => wrapped contents of the token.
    mapping(uint256 => WrappedContents) private wrappedContents;

    struct WrappedContents {
        address[] erc1155AssetContracts;
        uint256[][] erc1155TokensToWrap;
        uint256[][] erc1155AmountsToWrap;
        address[] erc721AssetContracts;
        uint256[][] erc721TokensToWrap;
        address[] erc20AssetContracts;
        uint256[] erc20AmountsToWrap;
    }

    event Wrapped(address indexed wrapper, uint256 indexed tokenIdOfShares, WrappedContents wrappedContents);
    event Unwrapped(address indexed wrapper, uint256 indexed tokenIdOfShares, WrappedContents wrappedContents);

    /// @dev Initiliazes the contract, like a constructor.
    function initialize(
        address _defaultAdmin,
        string memory _name,
        string memory _symbol,
        string memory _contractURI,
        address _trustedForwarder,
        address _royaltyRecipient,
        uint256 _royaltyBps
    ) external initializer {
        // Initialize inherited contracts, most base-like -> most derived.
        __ReentrancyGuard_init();
        __ERC2771Context_init(_trustedForwarder);
        __ERC1155_init("");

        // Initialize this contract's state.
        name = _name;
        symbol = _symbol;
        royaltyRecipient = _royaltyRecipient;
        royaltyBps = uint128(_royaltyBps);
        contractURI = _contractURI;

        _owner = _defaultAdmin;
        _setupRole(DEFAULT_ADMIN_ROLE, _defaultAdmin);
        _setupRole(MINTER_ROLE, _defaultAdmin);
        _setupRole(TRANSFER_ROLE, _defaultAdmin);
    }

    ///     =====   Public functions  =====

    /// @dev Returns the module type of the contract.
    function moduleType() external pure returns (bytes32) {
        return MODULE_TYPE;
    }

    /// @dev Returns the version of the contract.
    function version() external pure returns (uint8) {
        return uint8(VERSION);
    }

    /// @dev See ERC1155 - returns the metadata for a token.
    function uri(uint256 _tokenId) public view override returns (string memory) {
        return uriForShares[_tokenId];
    }

    /// @dev Alternative method to get the metadata for a token.
    function tokenURI(uint256 _tokenId) external view returns (string memory) {
        return uriForShares[_tokenId];
    }

    ///     =====   External functions  =====
    
    /// @dev Wrap multiple ERC1155, ERC721, ERC20 tokens into 'n' shares (i.e. variable supply of 1 ERC 1155 token)
    function wrap(
        WrappedContents calldata _wrappedContents,
        uint256 _shares,
        string calldata _uriForShares
    )
        external
        nonReentrant
    {
        uint256 tokenId = nextTokenIdToMint;
        nextTokenIdToMint += 1;

        uriForShares[tokenId] = _uriForShares;
        wrappedContents[tokenId] = _wrappedContents;

        _mint(msg.sender, tokenId, _shares, "");

        transferWrappedAssets(msg.sender, address(this), _wrappedContents);

        emit Wrapped(_msgSender(), tokenId, _wrappedContents);
    }

    /// @dev Unwrap shares to retrieve underlying ERC1155, ERC721, ERC20 tokens.
    function unwrap(uint256 _tokenId) external {
        uint256 totalSupplyOfToken = totalSupply[_tokenId];
        require(_tokenId < nextTokenIdToMint, "invalid tokenId");
        require(balanceOf(_msgSender(), _tokenId) == totalSupplyOfToken, "must own all shares to unwrap");

        WrappedContents memory wrappedContents_ = wrappedContents[_tokenId];

        delete wrappedContents[_tokenId];

        burn(msg.sender, _tokenId, totalSupplyOfToken);

        transferWrappedAssets(address(this), msg.sender, wrappedContents_);

        emit Unwrapped(_msgSender(), _tokenId, wrappedContents_);
    }

    ///     =====   Internal functions  =====

    function transferWrappedAssets(
        address _from,
        address _to,
        WrappedContents memory _wrappedContents
    ) 
        internal
    {
        // Logic divided up into internal functions to combat linter's `cycomatic complexity` error.
        transfer1155(_from, _to, _wrappedContents);
        transfer721(_from, _to, _wrappedContents);
        transfer20(_from, _to, _wrappedContents);

    }

    function transfer20(
        address _from,
        address _to,
        WrappedContents memory _wrappedContents
    ) 
        internal
    {
        uint256 i;

        bool isValidData =  _wrappedContents.erc20AssetContracts.length == _wrappedContents.erc20AmountsToWrap.length;
        require(isValidData, "invalid erc20 wrap");
        for(i = 0; i < _wrappedContents.erc20AssetContracts.length; i += 1) {
            CurrencyTransferLib.transferCurrency(
                _wrappedContents.erc20AssetContracts[i],
                _from,
                _to,
                _wrappedContents.erc20AmountsToWrap[i]
            );
        }
    }

    function transfer721(
        address _from,
        address _to,
        WrappedContents memory _wrappedContents
    ) 
        internal
    {
        uint256 i;
        uint256 j;

        bool isValidData =  _wrappedContents.erc721AssetContracts.length == _wrappedContents.erc721TokensToWrap.length;
        if(isValidData) {
            for(i = 0; i < _wrappedContents.erc721AssetContracts.length; i += 1) {
                IERC721 assetContract = IERC721(_wrappedContents.erc721AssetContracts[i]);
                
                for(j = 0; j < _wrappedContents.erc721TokensToWrap[i].length; j += 1) {
                    assetContract.safeTransferFrom(_from, _to, _wrappedContents.erc721TokensToWrap[i][j]);
                }
            }
        }
        require(isValidData, "invalid erc721 wrap");
    }

    function transfer1155(
        address _from,
        address _to,
        WrappedContents memory _wrappedContents
    ) 
        internal
    {
        uint256 i;
        uint256 j;

        bool isValidData =  _wrappedContents.erc1155AssetContracts.length == _wrappedContents.erc1155TokensToWrap.length
                && _wrappedContents.erc1155AssetContracts.length == _wrappedContents.erc1155AmountsToWrap.length;

        if(isValidData) {
            for(i = 0; i < _wrappedContents.erc1155AssetContracts.length; i += 1) {
                isValidData = _wrappedContents.erc1155TokensToWrap[i].length == _wrappedContents.erc1155AmountsToWrap[i].length;

                if(!isValidData) {
                    break;
                }

                IERC1155 assetContract = IERC1155(_wrappedContents.erc1155AssetContracts[i]);
                    
                for(j = 0; j < _wrappedContents.erc1155TokensToWrap[i].length; j += 1) {
                    assetContract.safeTransferFrom(_from, _to, _wrappedContents.erc1155TokensToWrap[i][j], _wrappedContents.erc1155AmountsToWrap[i][j], "");
                }
            }
        }
        require(isValidData, "invalid erc1155 wrap");
    }

    ///     =====   Low-level overrides  =====

    /// @dev Lets a token owner burn the tokens they own (i.e. destroy for good)
    function burn(
        address account,
        uint256 id,
        uint256 value
    ) public virtual {
        require(
            account == _msgSender() || isApprovedForAll(account, _msgSender()),
            "ERC1155: caller is not owner nor approved."
        );

        _burn(account, id, value);
    }

    /// @dev Lets a token owner burn multiple tokens they own at once (i.e. destroy for good)
    function burnBatch(
        address account,
        uint256[] memory ids,
        uint256[] memory values
    ) public virtual {
        require(
            account == _msgSender() || isApprovedForAll(account, _msgSender()),
            "ERC1155: caller is not owner nor approved."
        );

        _burnBatch(account, ids, values);
    }

    /**
     * @dev See {ERC1155-_beforeTokenTransfer}.
     */
    function _beforeTokenTransfer(
        address operator,
        address from,
        address to,
        uint256[] memory ids,
        uint256[] memory amounts,
        bytes memory data
    ) internal virtual override {
        super._beforeTokenTransfer(operator, from, to, ids, amounts, data);

        // if transfer is restricted on the contract, we still want to allow burning and minting
        if (isTransferRestricted && from != address(0) && to != address(0)) {
            require(hasRole(TRANSFER_ROLE, from) || hasRole(TRANSFER_ROLE, to), "restricted to TRANSFER_ROLE holders.");
        }

        if (from == address(0)) {
            for (uint256 i = 0; i < ids.length; ++i) {
                totalSupply[ids[i]] += amounts[i];
            }
        }

        if (to == address(0)) {
            for (uint256 i = 0; i < ids.length; ++i) {
                totalSupply[ids[i]] -= amounts[i];
            }
        }
    }

    function supportsInterface(bytes4 interfaceId)
        public
        view
        virtual
        override(AccessControlEnumerableUpgradeable, ERC1155Upgradeable)
        returns (bool)
    {
        return
            super.supportsInterface(interfaceId) ||
            interfaceId == type(IERC1155Upgradeable).interfaceId ||
            interfaceId == type(IERC2981).interfaceId;
    }

    function _msgSender()
        internal
        view
        virtual
        override(ContextUpgradeable, ERC2771ContextUpgradeable)
        returns (address sender)
    {
        return ERC2771ContextUpgradeable._msgSender();
    }

    function _msgData()
        internal
        view
        virtual
        override(ContextUpgradeable, ERC2771ContextUpgradeable)
        returns (bytes calldata)
    {
        return ERC2771ContextUpgradeable._msgData();
    }
}