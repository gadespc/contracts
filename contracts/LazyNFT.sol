// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.0;

// Token + Access Control
import "./openzeppelin-presets/ERC721PresetMinterPauserAutoId.sol";
import "@openzeppelin/contracts/interfaces/IERC165.sol";

// Protocol control center.
import { ProtocolControl } from "./ProtocolControl.sol";

// Royalties
import "@openzeppelin/contracts/interfaces/IERC2981.sol";

// Meta transactions
import "@openzeppelin/contracts/metatx/ERC2771Context.sol";
import "@openzeppelin/contracts/utils/cryptography/MerkleProof.sol";

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Multicall.sol";
import "@openzeppelin/contracts/utils/Strings.sol";

contract LazyNFT is ERC721PresetMinterPauserAutoId, ERC2771Context, IERC2981, ReentrancyGuard, Multicall {
    using Strings for uint256;

    /// @dev Only TRANSFER_ROLE holders can have tokens transferred from or to them, during restricted transfers.
    bytes32 public constant TRANSFER_ROLE = keccak256("TRANSFER_ROLE");

    /// @dev Whether transfers on tokens are restricted.
    bool public transfersRestricted;

    /// @dev The protocol control center.
    ProtocolControl internal controlCenter;

    uint256 public maxTotalSupply;

    /// @dev The token id of the NFT to "lazy mint".
    uint256 public nextTokenId;

    /// @dev The token Id of the NFT to mint.
    uint256 public nextMintTokenId;

    // public minting
    struct PublicMintCondition {
        uint256 startTimestamp;
        uint256 maxMintSupply;
        uint256 currentMintSupply;
        uint256 quantityLimitPerTransaction;
        uint256 waitTimeSecondsLimitPerTransaction;
        uint256 pricePerToken;
        address currency;
        bytes32 merkleRoot;
    }
    PublicMintCondition[] public mintConditions;
    // msg.sender address => current condition index => timestamp
    mapping(address => mapping(uint256 => uint256)) public nextMintTimestampByCondition;

    /// @dev Collection level metadata.
    string private _contractURI;

    string private _baseTokenURI;

    /// @dev Mapping from tokenId => URI
    mapping(uint256 => string) private uri;

    /// @dev Pack sale royalties -- see EIP 2981
    uint256 public royaltyBps;

    /// @dev Emitted when an NFT is minted;
    event Claimed(address indexed to, uint256 startTokenId, uint256 quantity, uint256 mintConditionIndex);
    event PublicMintConditionUpdated(PublicMintCondition[] mintConditions);
    event FundsWithdrawn(address indexed to, uint256 amount);
    event TotalSupplyUpdated(uint256 supply);
    event BaseTokenURIUpdated(string uri);
    event RestrictedTransferUpdated(bool transferable);
    event RoyaltyUpdated(uint256 royaltyBps);

    /// @dev Checks whether the protocol is paused.
    modifier onlyProtocolAdmin() {
        require(
            controlCenter.hasRole(controlCenter.DEFAULT_ADMIN_ROLE(), _msgSender()),
            "NFT: only a protocol admin can call this function."
        );
        _;
    }

    modifier onlyModuleAdmin() {
        require(hasRole(DEFAULT_ADMIN_ROLE, _msgSender()), "only module admin role");
        _;
    }

    constructor(
        address _controlCenter,
        string memory _name,
        string memory _symbol,
        address _trustedForwarder,
        string memory _contractUri,
        string memory _baseTokenUri,
        uint256 maxSupply
    ) ERC721PresetMinterPauserAutoId(_name, _symbol, _baseTokenUri) ERC2771Context(_trustedForwarder) {
        // Set the protocol control center
        controlCenter = ProtocolControl(_controlCenter);

        // Set contract URI
        _contractURI = _contractUri;

        maxTotalSupply = maxSupply;

        _setupRole(TRANSFER_ROLE, _msgSender());
    }

    /// @dev Revert inherited mint function.
    function mint(address) public pure override {
        revert("NFT: claim");
    }

    /// @dev Mints an NFT to `_to` with URI `_uri`
    function lazyMint(string calldata _uri) external whenNotPaused {
        require(hasRole(MINTER_ROLE, _msgSender()), "NFT: must have minter role to mint");
        require(nextTokenId + 1 <= maxTotalSupply, "NFT: cannot mint more than maxTotalSupply");
        uri[nextTokenId] = _uri;
        nextTokenId += 1;
    }

    function lazyMintBatch(string[] calldata _uris) external whenNotPaused {
        require(hasRole(MINTER_ROLE, _msgSender()), "NFT: must have minter role to mint");
        require((nextTokenId + _uris.length) <= maxTotalSupply, "NFT: cannot mint more than maxTotalSupply");
        uint256 id = nextTokenId;
        for (uint256 i = 0; i < _uris.length; i++) {
            uri[id] = _uris[i];
            id += 1;
        }
        nextTokenId = id;
    }

    function lazyMintAmount(uint256 amount) external whenNotPaused {
        require(hasRole(MINTER_ROLE, _msgSender()), "NFT: must have minter role to mint");
        require((nextTokenId + amount) <= maxTotalSupply, "NFT: cannot mint more than maxTotalSupply");
        nextTokenId += amount;
    }

    function claim(uint256 quantity, bytes32[] calldata proofs) external payable nonReentrant whenNotPaused {
        uint256 conditionIndex = getLastStartedMintConditionIndex();
        PublicMintCondition memory currentMintCondition = mintConditions[conditionIndex];

        require(quantity > 0, "NFT: quantity cannot be 0");
        require(nextMintTokenId + quantity <= maxTotalSupply, "NFT: exceeding total max supply limit");
        require(nextMintTokenId + quantity <= nextTokenId, "NFT: cannot claim unminted token");
        require(quantity <= currentMintCondition.quantityLimitPerTransaction, "NFT: exceeding supply limit");
        require(
            currentMintCondition.currentMintSupply + quantity <= currentMintCondition.maxMintSupply,
            "NFT: exceeding max mint supply"
        );

        uint256 nextMintTimestamp = nextMintTimestampByCondition[_msgSender()][conditionIndex];
        require(
            nextMintTimestamp == 0 || block.timestamp >= nextMintTimestamp,
            "NFT: cannot mint yet due to time limit"
        );

        if (currentMintCondition.merkleRoot != bytes32(0)) {
            bytes32 leaf = keccak256(abi.encodePacked(_msgSender()));
            require(MerkleProof.verify(proofs, currentMintCondition.merkleRoot, leaf), "NFT: invalid merkle proofs");
        }

        if (currentMintCondition.pricePerToken > 0) {
            _payout(currentMintCondition.currency, quantity * currentMintCondition.pricePerToken);
        }

        mintConditions[conditionIndex].currentMintSupply += quantity;
        nextMintTimestampByCondition[_msgSender()][conditionIndex] =
            block.timestamp +
            currentMintCondition.waitTimeSecondsLimitPerTransaction;

        uint256 startMintTokenId = nextMintTokenId;
        for (uint256 i = 0; i < quantity; i++) {
            _safeMint(_msgSender(), nextMintTokenId);
            nextMintTokenId += 1;
        }

        emit Claimed(_msgSender(), startMintTokenId, quantity, conditionIndex);
    }

    function _payout(address currency, uint256 amount) private {
        if (currency == address(0)) {
            require(msg.value == amount, "NFT: not enough value");
        } else {
            require(
                IERC20(currency).transferFrom(_msgSender(), controlCenter.getRoyaltyTreasury(address(this)), amount),
                "NFT: failed to transfer payment"
            );
        }
    }

    function withdrawFunds() external onlyProtocolAdmin {
        address to = controlCenter.getRoyaltyTreasury(address(this));
        uint256 balance = address(this).balance;
        (bool sent, ) = payable(to).call{ value: balance }("");
        require(sent, "NFT: failed to withdraw funds");

        emit FundsWithdrawn(to, balance);
    }

    function setPublicMintConditions(PublicMintCondition[] calldata conditions) external onlyModuleAdmin {
        require(conditions.length > 0, "NFT: needs a list of conditions");

        // `nextMintTimestampByCondition` does not get reset.
        delete mintConditions;

        // make sure the conditions are sorted in ascending order
        uint256 lastConditionStartTimestamp = 0;
        for (uint256 i = 0; i < conditions.length; i++) {
            // the input of startTimestamp is the number of seconds from now.
            if (lastConditionStartTimestamp != 0) {
                require(
                    lastConditionStartTimestamp < conditions[i].startTimestamp,
                    "NFT: startTimestamp must be in ascending order"
                );
            }
            require(conditions[i].maxMintSupply > 0, "NFT: max mint supply cannot be 0");
            require(conditions[i].quantityLimitPerTransaction > 0, "NFT: quantity limit cannot be 0");

            mintConditions.push(
                PublicMintCondition({
                    startTimestamp: block.timestamp + conditions[i].startTimestamp,
                    maxMintSupply: conditions[i].maxMintSupply,
                    currentMintSupply: 0,
                    quantityLimitPerTransaction: conditions[i].quantityLimitPerTransaction,
                    waitTimeSecondsLimitPerTransaction: conditions[i].waitTimeSecondsLimitPerTransaction,
                    pricePerToken: conditions[i].pricePerToken,
                    currency: conditions[i].currency,
                    merkleRoot: conditions[i].merkleRoot
                })
            );

            lastConditionStartTimestamp = conditions[i].startTimestamp;
        }

        emit PublicMintConditionUpdated(mintConditions);
    }

    function setMaxTotalSupply(uint256 maxSupply) external onlyModuleAdmin {
        maxTotalSupply = maxSupply;

        emit TotalSupplyUpdated(maxSupply);
    }

    function setBaseTokenURI(string calldata _uri) external onlyModuleAdmin {
        _baseTokenURI = _uri;

        emit BaseTokenURIUpdated(_uri);
    }

    /// @dev Lets a protocol admin update the royalties paid on pack sales.
    function setRoyaltyBps(uint256 _royaltyBps) external onlyModuleAdmin {
        require(_royaltyBps < controlCenter.MAX_BPS(), "NFT: Bps provided must be less than 10,000");

        royaltyBps = _royaltyBps;

        emit RoyaltyUpdated(_royaltyBps);
    }

    /// @dev Lets a protocol admin restrict token transfers.
    function setRestrictedTransfer(bool _restrictedTransfer) external onlyModuleAdmin {
        transfersRestricted = _restrictedTransfer;

        emit RestrictedTransferUpdated(_restrictedTransfer);
    }

    /// @dev Runs on every transfer.
    function _beforeTokenTransfer(
        address from,
        address to,
        uint256 tokenId
    ) internal virtual override(ERC721PresetMinterPauserAutoId) {
        super._beforeTokenTransfer(from, to, tokenId);

        // if transfer is restricted on the contract, we still want to allow burning and minting
        if (transfersRestricted && from != address(0) && to != address(0)) {
            require(
                hasRole(TRANSFER_ROLE, from) || hasRole(TRANSFER_ROLE, to),
                "NFT: Transfers are restricted to TRANSFER_ROLE holders"
            );
        }
    }


    /// @dev get the current active mint condition sorted by last added first
    /// assumption: the conditions are sorted ascending order by condition start timestamp. check on insertion.
    /// @return conition index, condition
    function getLastStartedMintConditionIndex() public view returns (uint256) {
        require(mintConditions.length > 0, "NFT: no public mint condition");
        for (uint256 i = mintConditions.length - 1; i >= 0; i--) {
            if (block.timestamp >= mintConditions[i].startTimestamp) {
                return i;
            }
        }
        revert("NFT: no active mint condition");
    }

    /// @dev See EIP 2981
    function royaltyInfo(uint256, uint256 salePrice)
        external
        view
        virtual
        override
        returns (address receiver, uint256 royaltyAmount)
    {
        receiver = controlCenter.getRoyaltyTreasury(address(this));
        royaltyAmount = (salePrice * royaltyBps) / controlCenter.MAX_BPS();
    }

    function supportsInterface(bytes4 interfaceId)
        public
        view
        virtual
        override(ERC721PresetMinterPauserAutoId, IERC165)
        returns (bool)
    {
        return super.supportsInterface(interfaceId) || interfaceId == type(IERC2981).interfaceId;
    }

    function tokenURI(uint256 tokenId) public view override returns (string memory) {
        require(_exists(tokenId), "ERC721Metadata: URI query for nonexistent token");
        string memory baseURI = _baseURI();
        if (bytes(uri[tokenId]).length > 0) {
            return uri[tokenId];
        }
        if (bytes(baseURI).length > 0) {
            return string(abi.encodePacked(baseURI, tokenId.toString()));
        }
        return "";
    }

    /// @dev Returns the URI for the storefront-level metadata of the contract.
    function contractURI() public view returns (string memory) {
        return _contractURI;
    }

    /// @dev Sets contract URI for the storefront-level metadata of the contract.
    function setContractURI(string calldata _URI) external onlyProtocolAdmin {
        _contractURI = _URI;
    }

    function _msgSender() internal view virtual override(Context, ERC2771Context) returns (address sender) {
        return ERC2771Context._msgSender();
    }

    function _msgData() internal view virtual override(Context, ERC2771Context) returns (bytes calldata) {
        return ERC2771Context._msgData();
    }

    function _baseURI() internal view virtual override returns (string memory) {
        return _baseTokenURI;
    }
}