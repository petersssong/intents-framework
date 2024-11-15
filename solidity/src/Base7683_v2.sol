// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.25;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { Address } from "@openzeppelin/contracts/utils/Address.sol";

import { TypeCasts } from "@hyperlane-xyz/libs/TypeCasts.sol";
import { IPermit2, ISignatureTransfer } from "@uniswap/permit2/src/interfaces/IPermit2.sol";

import {
    GaslessCrossChainOrder,
    OnchainCrossChainOrder,
    ResolvedCrossChainOrder,
    IOriginSettler,
    IDestinationSettler
} from "./ERC7683/IERC7683.sol";

abstract contract Base7683_v2 is IOriginSettler, IDestinationSettler {
    // ============ Libraries ============
    using SafeERC20 for IERC20;

    // ============ Constants ============

    IPermit2 public immutable PERMIT2;

    bytes32 public constant RESOLVED_CROSS_CHAIN_ORDER_TYPEHASH = keccak256(
        "ResolvedCrossChainOrder(address user, uint64 originChainId, uint32 openDeadline, uint32 fillDeadline, Output[] maxSpent, Output[] minReceived, FillInstruction[] fillInstructions)Output(bytes32 token, uint256 amount, bytes32 recipient, uint64 chainId)FillInstruction(uint64 destinationChainId, bytes32 destinationSettler, bytes originData)"
    );

    string public constant witnessTypeString =
        "ResolvedCrossChainOrder witness)ResolvedCrossChainOrder(address user, uint64 originChainId, uint32 openDeadline, uint32 fillDeadline, Output[] maxSpent, Output[] minReceived, FillInstruction[] fillInstructions)Output(bytes32 token, uint256 amount, bytes32 recipient, uint64 chainId)FillInstruction(uint64 destinationChainId, bytes32 destinationSettler, bytes originData)TokenPermissions(address token,uint256 amount)";

    // to be used to check the status of the order on orderStatus mapping. Other possible statuses should be defined in
    // the inheriting contract
    bytes32 public constant UNKNOWN = "";
    bytes32 public constant OPENED = "OPENED";
    bytes32 public constant FILLED = "FILLED";

    // ============ Public Storage ============

    mapping(address sender => uint256 nonce) public senderNonce;

    mapping(address => mapping(uint256 => uint256)) public nonceBitmap;

    mapping(bytes32 orderId => bytes resolvedOrder) public orders;

    mapping(bytes32 orderId => bytes originData) public filledOrders;

    mapping(bytes32 orderId => bytes fillerData) public orderFillerData;

    mapping(bytes32 orderId => bytes32 status) public orderStatus;

    // ============ Upgrade Gap ============

    uint256[47] private __GAP;

    // ============ Events ============

    event Filled(bytes32 orderId, bytes originData, bytes fillerData);
    /**
     *@notice Emits an event when the owner successfully invalidates an unordered nonce.
     */
    event UnorderedNonceInvalidation(address indexed owner, uint256 nonce);

    // ============ Errors ============

    error OrderOpenExpired();
    error InvalidOrderStatus();
    error InvalidGaslessOrderSettler();
    error InvalidGaslessOrderOrigin();
    error InvalidNonce();

    // ============ Constructor ============

    constructor(address _permit2) {
        PERMIT2 = IPermit2(_permit2);
    }

    // ============ Initializers ============

    // ============ External Functions ============

    /// @notice Opens a gasless cross-chain order on behalf of a user.
    /// @dev To be called by the filler.
    /// @dev This method must emit the Open event
    /// @param order The GaslessCrossChainOrder definition
    /// @param signature The user's signature over the order
    /// NOT USED originFillerData Any filler-defined data required by the settler
    function openFor(GaslessCrossChainOrder calldata order, bytes calldata signature, bytes calldata) external {
        if (block.timestamp > order.openDeadline) revert OrderOpenExpired();
        if (order.originSettler != address(this)) revert InvalidGaslessOrderSettler();
        if (order.originChainId != _localDomain()) revert InvalidGaslessOrderOrigin();

        (ResolvedCrossChainOrder memory resolvedOrder, bytes32 orderId, uint256 nonce) = _resolveOrder(order);

        _permitTransferFrom(resolvedOrder, signature, order.nonce, address(this));

        orders[orderId] = abi.encode(resolvedOrder);
        orderStatus[orderId] = OPENED;
        _useUnorderedNonce(order.user, nonce);

        emit Open(orderId, resolvedOrder);
    }

    /// @notice Opens a cross-chain order
    /// @dev To be called by the user
    /// @dev This method must emit the Open event
    /// @param order The OnchainCrossChainOrder definition
    function open(OnchainCrossChainOrder calldata order) external {
        (ResolvedCrossChainOrder memory resolvedOrder, bytes32 orderId, uint256 nonce) = _resolveOrder(order);

        for (uint256 i = 0; i < resolvedOrder.minReceived.length; i++) {
            IERC20(TypeCasts.bytes32ToAddress(resolvedOrder.minReceived[i].token)).safeTransferFrom(
                msg.sender, address(this), resolvedOrder.minReceived[i].amount
            );
        }

        orders[orderId] = abi.encode(resolvedOrder);
        orderStatus[orderId] = OPENED;
        _useUnorderedNonce(msg.sender, nonce);

        emit Open(orderId, resolvedOrder);
    }

    /// @notice Resolves a specific GaslessCrossChainOrder into a generic ResolvedCrossChainOrder
    /// @dev Intended to improve standardized integration of various order types and settlement contracts
    /// @param order The GaslessCrossChainOrder definition
    /// NOT USED originFillerData Any filler-defined data required by the settler
    /// @return resolvedOrder ResolvedCrossChainOrder hydrated order data including the inputs and outputs of the order
    function resolveFor(
        GaslessCrossChainOrder calldata order,
        bytes calldata
    )
        public
        view
        returns (ResolvedCrossChainOrder memory resolvedOrder)
    {
        (resolvedOrder,,) = _resolveOrder(order);
    }

    /// @notice Resolves a specific OnchainCrossChainOrder into a generic ResolvedCrossChainOrder
    /// @dev Intended to improve standardized integration of various order types and settlement contracts
    /// @param order The OnchainCrossChainOrder definition
    /// @return resolvedOrder ResolvedCrossChainOrder hydrated order data including the inputs and outputs of the order
    function resolve(OnchainCrossChainOrder calldata order)
        public
        view
        returns (ResolvedCrossChainOrder memory resolvedOrder)
    {
        (resolvedOrder,,) = _resolveOrder(order);
    }

    /// @notice Fills a single leg of a particular order on the destination chain
    /// @param _orderId Unique order identifier for this order
    /// @param _originData Data emitted on the origin to parameterize the fill
    /// @param _fillerData Data provided by the filler to inform the fill or express their preferences. It should
    /// contain the bytes32 encoded address of the receiver which is the used at settlement time
    function fill(bytes32 _orderId, bytes calldata _originData, bytes calldata _fillerData) external virtual {
        if (orderStatus[_orderId] != UNKNOWN) revert InvalidOrderStatus();

        _fillOrder(_orderId, _originData, _fillerData);

        orderStatus[_orderId] = FILLED;
        filledOrders[_orderId] = _originData;
        orderFillerData[_orderId] = _fillerData;

        emit Filled(_orderId, _originData, _fillerData);
    }

    // ============ Public Functions ============

    function witnessHash(ResolvedCrossChainOrder memory resolvedOrder) public pure returns (bytes32) {
        return keccak256(
            abi.encode(
                RESOLVED_CROSS_CHAIN_ORDER_TYPEHASH,
                resolvedOrder.user,
                resolvedOrder.originChainId,
                resolvedOrder.openDeadline,
                resolvedOrder.fillDeadline,
                resolvedOrder.maxSpent,
                resolvedOrder.minReceived,
                resolvedOrder.fillInstructions
            )
        );
    }

    /// @notice Invalidates the a nonce for the user calling the function
    /// @param nonce The nonce to get the associated word and bit positions
    function invalidateUnorderedNonces(uint256 nonce) external {
        _useUnorderedNonce(msg.sender, nonce);

        emit UnorderedNonceInvalidation(msg.sender, nonce);
    }

    // ============ Internal Functions ============

    /// @notice Returns the index of the bitmap and the bit position within the bitmap. Used for unordered nonces
    /// @param nonce The nonce to get the associated word and bit positions
    /// @return wordPos The word position or index into the nonceBitmap
    /// @return bitPos The bit position
    /// @dev The first 248 bits of the nonce value is the index of the desired bitmap
    /// @dev The last 8 bits of the nonce value is the position of the bit in the bitmap
    function bitmapPositions(uint256 nonce) private pure returns (uint256 wordPos, uint256 bitPos) {
        wordPos = uint248(nonce >> 8);
        bitPos = uint8(nonce);
    }

    /// @notice Checks whether a nonce is taken and sets the bit at the bit position in the bitmap at the word position
    /// @param from The address to use the nonce at
    /// @param nonce The nonce to spend
    function _useUnorderedNonce(address from, uint256 nonce) internal {
        (uint256 wordPos, uint256 bitPos) = bitmapPositions(nonce);
        uint256 bit = 1 << bitPos;
        uint256 flipped = nonceBitmap[from][wordPos] ^= bit;

        if (flipped & bit == 0) revert InvalidNonce();
    }

    function _permitTransferFrom(
        ResolvedCrossChainOrder memory resolvedOrder,
        bytes calldata signature,
        uint256 nonce,
        address receiver
    )
        internal
    {
        ISignatureTransfer.TokenPermissions[] memory permitted =
            new ISignatureTransfer.TokenPermissions[](resolvedOrder.minReceived.length);

        ISignatureTransfer.SignatureTransferDetails[] memory transferDetails =
            new ISignatureTransfer.SignatureTransferDetails[](resolvedOrder.minReceived.length);

        for (uint256 i = 0; i < resolvedOrder.minReceived.length; i++) {
            permitted[i] = ISignatureTransfer.TokenPermissions({
                token: TypeCasts.bytes32ToAddress(resolvedOrder.minReceived[i].token),
                amount: resolvedOrder.minReceived[i].amount
            });
            transferDetails[i] = ISignatureTransfer.SignatureTransferDetails({
                to: receiver,
                requestedAmount: resolvedOrder.minReceived[i].amount
            });
        }

        ISignatureTransfer.PermitBatchTransferFrom memory permit = ISignatureTransfer.PermitBatchTransferFrom({
            permitted: permitted,
            nonce: nonce,
            deadline: resolvedOrder.openDeadline
        });

        PERMIT2.permitWitnessTransferFrom(
            permit, transferDetails, resolvedOrder.user, witnessHash(resolvedOrder), witnessTypeString, signature
        );
    }

    /**
     * @dev To be implemented by the inheriting contract with specific logic fot the orderDataType and orderData
     */
    function _resolveOrder(GaslessCrossChainOrder memory order)
        internal
        view
        virtual
        returns (ResolvedCrossChainOrder memory, bytes32 orderId, uint256 nonce);

    /**
     * @dev To be implemented by the inheriting contract with specific logic fot the orderDataType and orderData
     */
    function _resolveOrder(OnchainCrossChainOrder memory order)
        internal
        view
        virtual
        returns (ResolvedCrossChainOrder memory, bytes32 orderId, uint256 nonce);

    function _fillOrder(bytes32 _orderId, bytes calldata _originData, bytes calldata _fillerData) internal virtual;

    /**
     * @dev To be implemented by the inheriting contract with specific logic, should return the local domain
     */
    function _localDomain() internal view virtual returns (uint32);
}
