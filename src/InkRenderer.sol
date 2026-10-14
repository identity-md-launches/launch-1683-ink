// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {Base64} from "@openzeppelin/contracts/utils/Base64.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";
import {AgentInputs, IInkRenderer} from "./interfaces/IInk.sol";

/// @notice Storage/transport only. Original art and trait algorithm have not been supplied or verified.
contract InkRenderer is Ownable2Step, IInkRenderer {
    using Strings for uint256;
    uint256 public constant MAX_CHUNK_BYTES = 8192;
    uint256 public constant MAX_SCRIPT_BYTES = 131072;
    uint256 public constant MAX_CHUNKS = 64;
    mapping(uint256 => bytes[]) private _uploads;
    uint256 public uploadVersion;
    uint256 public uploadedBytes;
    uint256 public expectedBytes;
    bytes32 public expectedHash;
    bool public scriptLocked;
    bool public previewLocked;
    string public previewURI;
    bytes32 public previewHash;

    error Locked();
    error InvalidUpload();
    error WrongIndex();
    error IncompleteUpload();
    error InvalidPreview();
    event UploadBegun(uint256 indexed version, uint256 size, bytes32 hash);
    event ChunkAppended(uint256 indexed version, uint256 indexed index, bytes32 hash);
    event ScriptLocked(bytes32 hash);
    event PreviewSet(bytes32 hash);
    event PreviewLocked();

    constructor(address initialOwner) Ownable(initialOwner) {}

    function beginUpload(uint256 previousVersion, uint256 size, bytes32 hash) external onlyOwner {
        if (scriptLocked) revert Locked();
        if (previousVersion != uploadVersion) revert WrongIndex();
        if (size == 0 || size > MAX_SCRIPT_BYTES || hash == bytes32(0)) revert InvalidUpload();
        // Start a fresh namespace; deleting a large old upload can exceed a transaction gas limit.
        uploadedBytes = 0;
        expectedBytes = size;
        expectedHash = hash;
        ++uploadVersion;
        emit UploadBegun(uploadVersion, size, hash);
    }

    function appendChunk(uint256 version, uint256 index, bytes calldata data) external onlyOwner {
        if (scriptLocked) revert Locked();
        if (version != uploadVersion || index != _uploads[uploadVersion].length) revert WrongIndex();
        if (
            index >= MAX_CHUNKS || data.length == 0 || data.length > MAX_CHUNK_BYTES
                || uploadedBytes + data.length > expectedBytes
        ) {
            revert InvalidUpload();
        }
        uploadedBytes += data.length;
        _uploads[uploadVersion].push(data);
        emit ChunkAppended(version, index, keccak256(data));
    }

    function chunkCount() external view returns (uint256) {
        return _uploads[uploadVersion].length;
    }

    function chunk(uint256 index) external view returns (bytes memory) {
        return _uploads[uploadVersion][index];
    }

    function script() public view returns (bytes memory result) {
        result = new bytes(uploadedBytes);
        uint256 offset = 0;
        bytes[] storage parts = _uploads[uploadVersion];
        for (uint256 i = 0; i < parts.length; ++i) {
            bytes memory part = parts[i];
            // Cancun MCOPY avoids per-byte loops for large owner-supplied scripts.
            assembly ("memory-safe") {
                mcopy(add(add(result, 0x20), offset), add(part, 0x20), mload(part))
            }
            offset += part.length;
        }
    }

    function lockScript(uint256 version, bytes32 hash) external onlyOwner {
        if (scriptLocked) revert Locked();
        if (version != uploadVersion || hash != expectedHash) revert WrongIndex();
        if (expectedBytes == 0 || uploadedBytes != expectedBytes || keccak256(script()) != expectedHash) {
            revert IncompleteUpload();
        }
        scriptLocked = true;
        emit ScriptLocked(expectedHash);
    }

    function setPreview(bytes calldata image, string calldata mediaType) external onlyOwner {
        if (previewLocked) revert Locked();
        bytes32 media = keccak256(bytes(mediaType));
        if (
            image.length == 0 || image.length > 32768
                || (media != keccak256("image/png")
                    && media != keccak256("image/jpeg")
                    && media != keccak256("image/svg+xml"))
        ) revert InvalidPreview();
        previewHash = keccak256(abi.encode(mediaType, image));
        previewURI = string.concat("data:", mediaType, ";base64,", Base64.encode(image));
        emit PreviewSet(previewHash);
    }

    function lockPreview(bytes32 hash) external onlyOwner {
        if (previewLocked) revert Locked();
        if (hash != previewHash) revert InvalidPreview();
        if (bytes(previewURI).length == 0) revert InvalidPreview();
        previewLocked = true;
        emit PreviewLocked();
    }

    function tokenURI(uint256 id, AgentInputs calldata inputs, bytes32 seed)
        external
        view
        returns (string memory)
    {
        string memory data = string.concat(
            '{"id":',
            id.toString(),
            ',"agent":',
            id < 2000 ? "true" : "false",
            ',"accepted":',
            uint256(inputs.accepted).toString(),
            ',"rateBps":',
            uint256(inputs.rateBps).toString(),
            ',"turns":',
            uint256(inputs.turns).toString(),
            ',"hoursTenths":',
            uint256(inputs.hoursTenths).toString(),
            ',"outdated":',
            inputs.outdated ? "true" : "false",
            ',"seed":"',
            uint256(seed).toHexString(32),
            '"}'
        );
        string memory header = string.concat(
            '<!doctype html><html><head><meta charset="utf-8">',
            '<meta http-equiv="Content-Security-Policy" content="default-src \'none\'; script-src \'unsafe-inline\' data:; ',
            'style-src \'unsafe-inline\'; img-src data:; connect-src \'none\'"></head><body>'
        );
        // Encode only the small HTML wrapper. Base64 characters are valid in this data URL
        // (data URLs do not use form-style '+' decoding). This avoids re-encoding a large script twice.
        string memory animation = scriptLocked
            ? string.concat(
                "data:text/html,",
                _uriEncode(
                    bytes(
                        string.concat(
                            header,
                            "<script>window.INK_INPUTS=",
                            data,
                            ';</script><script src="data:text/javascript;base64,'
                        )
                    )
                ),
                Base64.encode(script()),
                _uriEncode(bytes('"></script></body></html>'))
            )
            : string.concat(
                "data:text/html,",
                _uriEncode(
                    bytes(
                        string.concat(
                            header,
                            "<p>Original art and trait integration pending. No algorithm has been supplied.</p></body></html>"
                        )
                    )
                )
            );
        bytes memory json = abi.encodePacked(
            '{"name":"Ink & Inference #',
            id.toString(),
            '","description":"Original art/trait integration pending independent verification; raw fixed inputs only.",',
            '"image":"',
            previewURI,
            '","animation_url":"',
            animation,
            '","ink_inputs":',
            data,
            "}"
        );
        return string.concat("data:application/json;base64,", Base64.encode(json));
    }

    /// @dev All wrapper/input bytes are percent-encoded. Large base64 script data bypasses this small loop.
    function _uriEncode(bytes memory data) private pure returns (string memory) {
        bytes16 alphabet = "0123456789ABCDEF";
        bytes memory result = new bytes(data.length * 3);
        for (uint256 i = 0; i < data.length; ++i) {
            uint8 value = uint8(data[i]);
            result[3 * i] = "%";
            result[3 * i + 1] = alphabet[value >> 4];
            result[3 * i + 2] = alphabet[value & 15];
        }
        return string(result);
    }
}
