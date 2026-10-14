// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Base64} from "@openzeppelin/contracts/utils/Base64.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";
import {InkPortraits} from "../src/InkPortraits.sol";
import {InkRenderer} from "../src/InkRenderer.sol";
import {AgentInputs} from "../src/interfaces/IInk.sol";

contract PortraitsRendererTest is Test {
    InkPortraits internal portraits;
    InkRenderer internal renderer;
    address internal initialOwner = makeAddr("explicit owner");
    address internal vault = makeAddr("vault");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    AgentInputs internal inputs = AgentInputs(type(uint32).max, 10000, type(uint32).max, 123, true);

    function setUp() public {
        portraits = new InkPortraits(initialOwner);
        renderer = new InkRenderer(initialOwner);
        vm.startPrank(initialOwner);
        portraits.configureVault(vault);
        portraits.setRenderer(renderer);
        vm.stopPrank();
    }

    function _mint() internal {
        vm.prank(vault);
        portraits.mintAgent(alice, 1999, inputs);
    }

    function testNamesAccessRoyaltiesAndTransfers() public {
        assertEq(portraits.name(), "Ink & Inference");
        assertEq(portraits.symbol(), "INKINF");
        assertEq(portraits.owner(), initialOwner);
        vm.expectRevert(InkPortraits.OnlyVault.selector);
        portraits.mintAgent(alice, 1, inputs);
        vm.expectRevert();
        portraits.configureVault(bob);
        vm.expectRevert(InkPortraits.InvalidConfiguration.selector);
        vm.prank(initialOwner);
        portraits.configureVault(bob);
        _mint();
        (address recipient, uint256 amount) = portraits.royaltyInfo(1999, 100 ether);
        assertEq(recipient, initialOwner);
        assertEq(amount, 5 ether);
        assertTrue(portraits.supportsInterface(0x2a55205a));
        assertTrue(portraits.supportsInterface(0x80ac58cd));
        assertEq(portraits.agentInputs(1999).accepted, type(uint32).max);
        vm.prank(alice);
        portraits.transferFrom(alice, bob, 1999);
        assertEq(portraits.agentBalance(alice), 0);
        assertEq(portraits.agentBalance(bob), 1);
        vm.prank(bob);
        portraits.transferFrom(bob, bob, 1999);
        assertEq(portraits.agentBalance(bob), 1);
        vm.prank(vault);
        portraits.mintSwarm(bob, keccak256("swarm"));
        assertEq(portraits.agentBalance(bob), 1);
        vm.expectRevert();
        portraits.tokenURI(42);
        vm.expectRevert();
        portraits.agentInputs(42);
    }

    function testCombinedCapacityDuplicateAndIds() public {
        vm.startPrank(vault);
        portraits.mintAgent(alice, 0, inputs);
        vm.expectRevert();
        portraits.mintAgent(bob, 0, inputs);
        vm.expectRevert(InkPortraits.InvalidSeat.selector);
        portraits.mintAgent(alice, 2000, inputs);
        AgentInputs memory bad = inputs;
        bad.rateBps = 10001;
        vm.expectRevert(InkPortraits.InvalidSeat.selector);
        portraits.mintAgent(alice, 1, bad);
        for (uint256 i = 0; i < 1999; ++i) {
            assertEq(portraits.mintSwarm(alice, bytes32(i)), 10000 + i);
        }
        vm.expectRevert(InkPortraits.Capacity.selector);
        portraits.mintSwarm(alice, bytes32(0));
        vm.expectRevert(InkPortraits.Capacity.selector);
        portraits.mintAgent(alice, 1, inputs);
        vm.stopPrank();
        assertEq(portraits.totalSupply(), 2000);
    }

    function testTwoStepOwnershipAndRendererSelectionLock() public {
        vm.prank(initialOwner);
        portraits.transferOwnership(alice);
        assertEq(portraits.owner(), initialOwner);
        vm.expectRevert();
        vm.prank(bob);
        portraits.acceptOwnership();
        vm.prank(alice);
        portraits.acceptOwnership();
        assertEq(portraits.owner(), alice);
        InkRenderer next = new InkRenderer(alice);
        vm.prank(alice);
        portraits.setRenderer(next);
        vm.prank(alice);
        portraits.lockRenderer();
        vm.expectRevert(InkPortraits.InvalidConfiguration.selector);
        vm.prank(alice);
        portraits.setRenderer(renderer);
        assertTrue(portraits.rendererLocked());
        assertFalse(next.scriptLocked());
    }

    function testScriptUploadResumeHashAndLocks() public {
        bytes memory a = bytes("// SYNTHETIC TRANSPORT TEST ONLY\n");
        bytes memory b = bytes("window.testFlag = true;");
        bytes memory entire = bytes.concat(a, b);
        vm.expectRevert();
        renderer.beginUpload(0, entire.length, keccak256(entire));
        vm.startPrank(initialOwner);
        renderer.beginUpload(renderer.uploadVersion(), entire.length, keccak256(entire));
        renderer.appendChunk(1, 0, a);
        vm.expectRevert(InkRenderer.WrongIndex.selector);
        renderer.appendChunk(1, 0, a);
        vm.expectRevert(InkRenderer.WrongIndex.selector);
        renderer.appendChunk(2, 1, b);
        uint256 v = renderer.uploadVersion();
        bytes32 h = renderer.expectedHash();
        vm.expectRevert(InkRenderer.IncompleteUpload.selector);
        renderer.lockScript(v, h);
        renderer.appendChunk(1, 1, b);
        assertEq(renderer.script(), entire);
        assertEq(renderer.chunk(0), a);
        assertEq(renderer.chunkCount(), 2);
        renderer.lockScript(renderer.uploadVersion(), renderer.expectedHash());
        assertTrue(renderer.scriptLocked());
        assertFalse(renderer.previewLocked());
        vm.expectRevert(InkRenderer.Locked.selector);
        renderer.beginUpload(1, 1, keccak256("x"));
        vm.expectRevert(InkRenderer.Locked.selector);
        renderer.appendChunk(1, 2, "x");
        renderer.setPreview("synthetic bytes", "image/png");
        renderer.lockPreview(renderer.previewHash());
        vm.expectRevert(InkRenderer.Locked.selector);
        renderer.setPreview("x", "image/png");
        vm.stopPrank();
    }

    function testHashMismatchNewUploadAndIndependentPreviewLock() public {
        vm.startPrank(initialOwner);
        renderer.beginUpload(renderer.uploadVersion(), 3, keccak256("abc"));
        renderer.appendChunk(1, 0, "bad");
        vm.expectRevert(InkRenderer.IncompleteUpload.selector);
        renderer.lockScript(1, keccak256("abc"));
        renderer.beginUpload(renderer.uploadVersion(), 3, keccak256("abc"));
        assertEq(renderer.uploadedBytes(), 0);
        assertEq(renderer.chunkCount(), 0);
        vm.expectRevert(InkRenderer.WrongIndex.selector);
        renderer.appendChunk(1, 0, "abc");
        renderer.appendChunk(2, 0, "abc");
        renderer.setPreview("image", "image/svg+xml");
        renderer.lockPreview(renderer.previewHash());
        assertFalse(renderer.scriptLocked());
        renderer.lockScript(renderer.uploadVersion(), renderer.expectedHash());
        assertTrue(renderer.scriptLocked());
        vm.stopPrank();
    }

    function testUploadBoundsAndPreviewValidation() public {
        vm.startPrank(initialOwner);
        vm.expectRevert(InkRenderer.InvalidUpload.selector);
        renderer.beginUpload(0, 0, keccak256("x"));
        vm.expectRevert(InkRenderer.InvalidUpload.selector);
        renderer.beginUpload(0, 131073, keccak256("x"));
        vm.expectRevert(InkRenderer.InvalidUpload.selector);
        renderer.beginUpload(0, 1, bytes32(0));
        renderer.beginUpload(renderer.uploadVersion(), 10000, keccak256("x"));
        vm.expectRevert(InkRenderer.InvalidUpload.selector);
        renderer.appendChunk(1, 0, new bytes(8193));
        vm.expectRevert(InkRenderer.InvalidUpload.selector);
        renderer.appendChunk(1, 0, "");
        vm.expectRevert(InkRenderer.InvalidPreview.selector);
        renderer.setPreview("x", 'image/png","bad":"');
        vm.expectRevert(InkRenderer.InvalidPreview.selector);
        renderer.setPreview("", "image/png");
        vm.expectRevert(InkRenderer.InvalidPreview.selector);
        renderer.lockPreview(bytes32(0));
        vm.stopPrank();
    }

    function testOnchainJSONAndPendingAnimationThenOriginalScriptTransport() public {
        _mint();
        string memory json = _decodeDataURI(portraits.tokenURI(1999));
        assertEq(vm.parseJsonString(json, ".name"), "Ink & Inference #1999");
        assertEq(vm.parseJsonUint(json, ".ink_inputs.accepted"), type(uint32).max);
        assertTrue(vm.parseJsonBool(json, ".ink_inputs.outdated"));
        string memory html = _decodeDataURI(vm.parseJsonString(json, ".animation_url"));
        assertTrue(_contains(html, "Original art and trait integration pending"));
        // Script containing </script> is encoded, so it cannot escape the enclosing HTML element.
        bytes memory script = bytes("// synthetic </script> boundary test only");
        vm.startPrank(initialOwner);
        renderer.beginUpload(renderer.uploadVersion(), script.length, keccak256(script));
        renderer.appendChunk(1, 0, script);
        renderer.lockScript(renderer.uploadVersion(), renderer.expectedHash());
        vm.stopPrank();
        json = _decodeDataURI(portraits.tokenURI(1999));
        html = _decodeDataURI(vm.parseJsonString(json, ".animation_url"));
        assertTrue(_contains(html, 'window.INK_INPUTS={"id":1999'));
        assertTrue(_contains(html, Base64.encode(script)));
        assertFalse(_contains(html, "synthetic </script>"));
        assertTrue(_contains(html, "connect-src 'none'"));
    }

    function testStaleBeginAndLockTransactionsFail() public {
        vm.startPrank(initialOwner);
        renderer.beginUpload(0, 3, keccak256("abc"));
        vm.expectRevert(InkRenderer.WrongIndex.selector);
        renderer.beginUpload(0, 3, keccak256("new"));
        renderer.appendChunk(1, 0, "abc");
        vm.expectRevert(InkRenderer.WrongIndex.selector);
        renderer.lockScript(2, keccak256("abc"));
        vm.expectRevert(InkRenderer.WrongIndex.selector);
        renderer.lockScript(1, keccak256("wrong"));
        renderer.setPreview("image", "image/png");
        bytes32 originalHash = renderer.previewHash();
        renderer.setPreview("image", "image/svg+xml");
        vm.expectRevert(InkRenderer.InvalidPreview.selector);
        renderer.lockPreview(originalHash);
        vm.stopPrank();
    }

    function testExcessChunkCountRejectedAndRestartIsFresh() public {
        vm.startPrank(initialOwner);
        renderer.beginUpload(0, 65, keccak256("not yet complete"));
        for (uint256 i = 0; i < 64; ++i) {
            renderer.appendChunk(1, i, "x");
        }
        vm.expectRevert(InkRenderer.InvalidUpload.selector);
        renderer.appendChunk(1, 64, "x");
        renderer.beginUpload(1, 3, keccak256("abc"));
        assertEq(renderer.chunkCount(), 0);
        assertEq(renderer.uploadedBytes(), 0);
        renderer.appendChunk(2, 0, "abc");
        renderer.lockScript(2, keccak256("abc"));
        assertEq(renderer.script(), bytes("abc"));
        vm.stopPrank();
    }

    function testFuzzRawInputsRoundTrip(
        uint32 accepted,
        uint16 rate,
        uint32 turns,
        uint32 hoursTenths,
        bool outdated
    ) public view {
        AgentInputs memory data = AgentInputs(accepted, rate, turns, hoursTenths, outdated);
        string memory json = _decodeDataURI(renderer.tokenURI(10, data, bytes32(uint256(1234))));
        assertEq(vm.parseJsonUint(json, ".ink_inputs.accepted"), accepted);
        assertEq(vm.parseJsonUint(json, ".ink_inputs.rateBps"), rate);
        assertEq(vm.parseJsonUint(json, ".ink_inputs.turns"), turns);
        assertEq(vm.parseJsonUint(json, ".ink_inputs.hoursTenths"), hoursTenths);
        assertEq(vm.parseJsonBool(json, ".ink_inputs.outdated"), outdated);
    }

    function _contains(string memory haystack, string memory needle) private pure returns (bool) {
        bytes memory a = bytes(haystack);
        bytes memory b = bytes(needle);
        if (b.length > a.length) return false;
        for (uint256 i = 0; i <= a.length - b.length; ++i) {
            bool same = true;
            for (uint256 j = 0; j < b.length; ++j) {
                if (a[i + j] != b[j]) {
                    same = false;
                    break;
                }
            }
            if (same) return true;
        }
        return false;
    }

    function _hexValue(bytes1 value) private pure returns (uint8) {
        uint8 v = uint8(value);
        return v <= 57 ? v - 48 : v - 55;
    }

    function _decodeDataURI(string memory uri) private pure returns (string memory) {
        bytes memory s = bytes(uri);
        uint256 start = 0;
        while (s[start] != bytes1(",")) ++start;
        ++start;
        if (start == bytes("data:text/html,").length) {
            bytes memory decoded = new bytes(s.length - start);
            uint256 count = 0;
            for (uint256 i = start; i < s.length; ++i) {
                if (s[i] == "%") {
                    decoded[count++] = bytes1(uint8((_hexValue(s[i + 1]) << 4) | _hexValue(s[i + 2])));
                    i += 2;
                } else {
                    decoded[count++] = s[i];
                }
            }
            assembly ("memory-safe") { mstore(decoded, count) }
            return string(decoded);
        }
        uint256 end = s.length;
        uint256 padding = 0;
        if (s[end - 1] == "=") ++padding;
        if (s[end - 2] == "=") ++padding;
        bytes memory result = new bytes((end - start) / 4 * 3 - padding);
        uint256 index = 0;
        uint256 acc = 0;
        uint256 bits = 0;
        for (uint256 i = start; i < end && s[i] != "="; ++i) {
            uint8 c = uint8(s[i]);
            uint256 value;
            if (c >= 65 && c <= 90) value = c - 65;
            else if (c >= 97 && c <= 122) value = c - 71;
            else if (c >= 48 && c <= 57) value = c + 4;
            else if (c == 43) value = 62;
            else value = 63;
            acc = (acc << 6) | value;
            bits += 6;
            if (bits >= 8) {
                bits -= 8;
                result[index++] = bytes1(uint8(acc >> bits));
            }
        }
        return string(result);
    }
}

contract RendererSizeTest is Test {
    InkRenderer internal renderer;
    bytes32 internal expected;

    function setUp() public {
        renderer = new InkRenderer(address(this));
        bytes memory part = new bytes(8192);
        for (uint256 i = 0; i < part.length; ++i) {
            part[i] = bytes1(uint8(i));
        }
        bytes memory complete = new bytes(131072);
        for (uint256 i = 0; i < complete.length; i += part.length) {
            assembly ("memory-safe") { mcopy(add(add(complete, 0x20), i), add(part, 0x20), mload(part)) }
        }
        expected = keccak256(complete);
        renderer.beginUpload(0, complete.length, expected);
        for (uint256 i = 0; i < 16; ++i) {
            renderer.appendChunk(1, i, part);
        }
        // Synthetic transport bytes only; no original artwork is supplied.
        renderer.setPreview(new bytes(32768), "image/png");
    }

    function testMaximumAnimationMetadataFitsCallBudget() public {
        renderer.lockScript(1, expected);
        uint256 beforeGas = gasleft();
        string memory uri = renderer.tokenURI(10000, AgentInputs(0, 0, 0, 0, false), expected);
        uint256 used = beforeGas - gasleft();
        assertGt(bytes(uri).length, 131072);
        assertLt(used, 50000000);
        emit log_named_uint("Maximum script and preview tokenURI gas", used);
    }

    function testRestartMaximumUploadUsesBoundedGas() public {
        uint256 beforeGas = gasleft();
        renderer.beginUpload(1, 3, keccak256("abc"));
        assertLt(beforeGas - gasleft(), 150000);
        assertEq(renderer.chunkCount(), 0);
        assertEq(renderer.uploadedBytes(), 0);
        renderer.appendChunk(2, 0, "abc");
        renderer.lockScript(2, keccak256("abc"));
        assertEq(renderer.script(), bytes("abc"));
    }

    function testMaximumScriptRoundTripAndLockGasBound() public {
        uint256 beforeGas = gasleft();
        renderer.lockScript(1, expected);
        uint256 used = beforeGas - gasleft();
        assertLt(used, 12000000);
        assertEq(keccak256(renderer.script()), expected);
        assertEq(renderer.uploadedBytes(), 131072);
        emit log_named_uint("Maximum script lock gas (cold test transaction)", used);
    }
}
