// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {SwarmDerby, IERC20, IArbSys} from "../src/SwarmDerby.sol";
import {MockIMD, MockArbSys} from "./SwarmDerby.t.sol";

/// @dev Test-only equivalent of the launch floor's zero-value CREATE2 probe.
contract SwarmDerbyLaunchProbe {
    address private immutable controller = msg.sender;

    function deploy(bytes memory code, bytes32 salt) external returns (address deployed) {
        require(msg.sender == controller, "not the test harness");
        require(code.length > 0 && code.length <= 49_152, "invalid init code");
        assembly ("memory-safe") {
            deployed := create2(0, add(code, 32), mload(code), salt)
        }
        require(deployed != address(0) && deployed.code.length > 0, "application constructor failed");
    }
}

contract SwarmDerbyLaunchTest is Test {
    address constant IMD = 0x5F7Bb59365ce557C26dbcAa4EE9d39A4b95B7127;
    address constant OWNER = address(0xA11); // Local stand-in for the launch's $owner.
    uint256 constant SINGLE_PRICE = 150000000000000000;
    uint256 constant PACK_PRICE = 500000000000000000;
    bytes32 constant SALT = keccak256("SwarmDerby launch rehearsal");

    SwarmDerbyLaunchProbe factory;

    function setUp() public {
        vm.chainId(4663);
        vm.warp(20_370 days + 1 hours);
        // These model existing chain dependencies, never launch outputs.
        vm.etch(IMD, type(MockIMD).runtimeCode);
        address arbMock = address(new MockArbSys());
        vm.etch(address(100), arbMock.code);
        vm.mockFunction(address(100), arbMock, abi.encodeWithSelector(IArbSys.arbBlockNumber.selector));
        vm.mockFunction(address(100), arbMock, abi.encodeWithSelector(IArbSys.arbBlockHash.selector));
        MockArbSys(address(100)).setBlock(1_000);
        factory = new SwarmDerbyLaunchProbe();
    }

    function _initCode() internal pure returns (bytes memory) {
        return abi.encodePacked(type(SwarmDerby).creationCode, abi.encode(OWNER, IERC20(IMD), SINGLE_PRICE, PACK_PRICE));
    }

    function _deploy() internal returns (SwarmDerby) {
        return SwarmDerby(factory.deploy(_initCode(), SALT));
    }

    function test_factoryDeploysOnlyDerbyFullyConfigured() public {
        bytes memory initCode = _initCode();
        address predicted = vm.computeCreate2Address(SALT, keccak256(initCode), address(factory));
        uint64 factoryNonce = vm.getNonce(address(factory));
        SwarmDerby derby = SwarmDerby(factory.deploy(initCode, SALT));

        assertEq(address(derby), predicted);
        assertEq(vm.getNonce(address(factory)), factoryNonce + 1);
        assertEq(vm.getNonce(address(derby)), 1, "constructor must not create children");
        assertEq(address(derby).balance, 0);
        assertEq(derby.owner(), OWNER);
        assertEq(derby.pendingOwner(), address(0));
        assertEq(address(derby.imd()), IMD);
        assertEq(derby.singlePrice(), SINGLE_PRICE);
        assertEq(derby.packPrice(), PACK_PRICE);
        assertEq(derby.openDays(0).length, 0);
        assertEq(derby.openDays(1).length, 0);

        bytes memory runtime = address(derby).code;
        assertGt(runtime.length, 0);
        assertLe(runtime.length, 24_576);
        // Match the protected floor: skip PUSH data when checking opcodes.
        for (uint256 i; i < runtime.length; ++i) {
            uint8 op = uint8(runtime[i]);
            if (op >= 0x60 && op <= 0x7f) {
                i += op - 0x5f;
                continue;
            }
            assertTrue(op != 0xf4 && op != 0xf2 && op != 0xff, "forbidden application opcode");
        }

        vm.prank(address(factory));
        vm.expectRevert(SwarmDerby.NotOwner.selector);
        derby.setPrices(SINGLE_PRICE, PACK_PRICE);
        vm.prank(OWNER);
        derby.setPrices(SINGLE_PRICE, PACK_PRICE);
    }

    /// @dev Reproduces audit 980f397e: a chain ID alone supplies no token code.
    function test_emptyChainRehearsalRequiresImdCode() public {
        vm.etch(IMD, hex"");
        assertEq(IMD.code.length, 0);
        vm.expectRevert(SwarmDerby.NotAContract.selector);
        new SwarmDerby(OWNER, IERC20(IMD), SINGLE_PRICE, PACK_PRICE);

        bytes memory initCode = _initCode();
        vm.expectRevert(bytes("application constructor failed"));
        factory.deploy(initCode, SALT);
    }

    function test_factoryDeploymentCanBuyImmediatelyWithPinnedToken() public {
        SwarmDerby derby = _deploy();
        MockIMD imd = MockIMD(IMD);
        address player = address(0xBA77E2);
        imd.mint(player, SINGLE_PRICE + PACK_PRICE);
        vm.startPrank(player);
        imd.approve(address(derby), SINGLE_PRICE + PACK_PRICE);
        derby.buyTurns(0, 1);
        derby.buyPacks(1, 1);
        vm.stopPrank();

        assertEq(derby.turns(0, player), 1);
        assertEq(derby.turns(1, player), 5);
        assertEq(imd.balanceOf(player), 0);
        assertEq(imd.balanceOf(derby.DEAD()), 260000000000000000);
        assertEq(derby.pot(0), 67500000000000000);
        assertEq(derby.pot(1), 225000000000000000);
        assertEq(derby.vault(0), 15000000000000000);
        assertEq(derby.vault(1), 50000000000000000);
        assertEq(derby.opsBalance(), 32500000000000000);
        assertEq(imd.balanceOf(address(derby)), 390000000000000000);
    }

    /// @dev Reproduces audit 4f16c38c and verifies the existing escape mechanism.
    function test_fundedSessionSignerRedirectsActivityUntilItLeaves() public {
        SwarmDerby derby = _deploy();
        MockIMD imd = MockIMD(IMD);
        uint256 signerKey = 0xF00D; // Deterministic test identity, never a deployment key.
        address signer = vm.addr(signerKey);
        address otherPlayer = address(0xBAD);
        imd.mint(signer, 10 ether);
        vm.startPrank(signer);
        imd.approve(address(derby), 12 * SINGLE_PRICE);
        derby.buyTurns(0, 10);
        vm.stopPrank();
        assertEq(imd.balanceOf(signer), 8.5 ether);

        (uint8 v, bytes32 r, bytes32 s) = vm.sign(signerKey, derby.sessionDigest(otherPlayer, signer));
        vm.prank(otherPlayer);
        derby.setSession(signer, abi.encodePacked(r, s, v));
        assertEq(derby.playerOf(signer), otherPlayer);

        // Its original ten turns cannot be spent while it acts for the other player.
        bytes32 commit = derby.commitFor(SALT, otherPlayer);
        vm.prank(signer);
        vm.expectRevert(SwarmDerby.NoTurns.selector);
        derby.swing(0, 100, 100, commit);
        vm.prank(signer);
        derby.buyTurns(0, 2);
        assertEq(imd.balanceOf(signer), 8.2 ether);
        assertEq(imd.balanceOf(otherPlayer), 0);
        assertEq(derby.turns(0, signer), 10);
        assertEq(derby.turns(0, otherPlayer), 2);
        vm.prank(signer);
        uint256 id = derby.swing(0, 100, 100, commit);
        (address credited,,,,,,,) = derby.swings(id);
        assertEq(credited, otherPlayer);
        assertEq(derby.turns(0, otherPlayer), 1);
        assertEq(derby.turns(0, signer), 10);

        vm.prank(signer);
        derby.leaveSession();
        assertEq(derby.playerOf(signer), signer);
        assertEq(derby.sessionOf(otherPlayer), address(0));
        assertEq(derby.sessionNonce(signer), 1);
        vm.prank(otherPlayer);
        vm.expectRevert(SwarmDerby.BadSession.selector);
        derby.setSession(signer, abi.encodePacked(r, s, v));
        commit = derby.commitFor(SALT, signer);
        vm.prank(signer);
        id = derby.swing(0, 100, 100, commit);
        (credited,,,,,,,) = derby.swings(id);
        assertEq(credited, signer);
        assertEq(derby.turns(0, signer), 9);
    }
}
