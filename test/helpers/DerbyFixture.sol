// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {SwarmDerby, IERC20, IArbSys} from "src/SwarmDerby.sol";
import {DerbyOdds} from "src/DerbyOdds.sol";
import {MockArbSys} from "../SwarmDerby.t.sol";

/// @dev Offline dependency stand-in: exact transfers, optional return data and recipient rejection.
/// Refused transfers never move tokens. This does not claim to reproduce live IMD bytecode.
contract DerbyTestToken {
    enum Response {
        Normal,
        Empty,
        False,
        Revert,
        Short
    }

    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    mapping(address => Response) public responseTo;
    Response public pullResponse;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function setPullResponse(Response response) external {
        pullResponse = response;
    }

    function setResponse(address to, Response response) external {
        responseTo[to] = response;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        Response response = pullResponse;
        _reject(response);
        allowance[from][msg.sender] -= amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return _success(response);
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        Response response = responseTo[to];
        _reject(response);
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return _success(response);
    }

    function _reject(Response response) private pure {
        if (response == Response.Revert) revert("token rejected transfer");
        if (response == Response.False) {
            assembly ("memory-safe") {
                mstore(0, 0)
                return(0, 32)
            }
        }
        if (response == Response.Short) {
            assembly ("memory-safe") {
                mstore(0, 0)
                return(0, 1)
            }
        }
    }

    function _success(Response response) private pure returns (bool) {
        if (response == Response.Empty) {
            assembly ("memory-safe") { return(0, 0) }
        }
        return true;
    }
}

abstract contract DerbyFixture is Test {
    address internal constant IMD = 0x5F7Bb59365ce557C26dbcAa4EE9d39A4b95B7127;
    address internal constant ALICE = address(0xA11CE);
    address internal constant BOB = address(0xB0B);
    address internal constant KEEPER = address(0xCEE);
    uint256 internal constant START_DAY = 20_370;
    bytes32 internal constant SALT = keccak256("adversarial test salt");
    SwarmDerby internal derby;
    DerbyTestToken internal token;
    MockArbSys internal arb;

    function setUp() public virtual {
        vm.chainId(4663);
        vm.warp(START_DAY * 1 days + 1 hours);
        vm.etch(IMD, type(DerbyTestToken).runtimeCode);
        token = DerbyTestToken(IMD);
        address implementation = address(new MockArbSys());
        vm.etch(address(100), implementation.code);
        vm.mockFunction(address(100), implementation, abi.encodeWithSelector(IArbSys.arbBlockNumber.selector));
        vm.mockFunction(address(100), implementation, abi.encodeWithSelector(IArbSys.arbBlockHash.selector));
        arb = MockArbSys(address(100));
        arb.setBlock(1_000);
        derby = new SwarmDerby(address(this), IERC20(IMD), 150000000000000000, 500000000000000000);
        _fund(ALICE, 100 ether);
        _fund(BOB, 100 ether);
    }

    function _fund(address who, uint256 amount) internal {
        token.mint(who, amount);
        vm.prank(who);
        token.approve(address(derby), type(uint256).max);
    }

    function _buy(address who, uint8 league, uint256 count) internal {
        vm.prank(who);
        derby.buyTurns(league, count);
    }

    function _commit(address who, uint8 league, uint8 quality, bytes32 salt) internal returns (uint256) {
        bytes32 commitment = keccak256(abi.encode(salt, who));
        vm.prank(who);
        return derby.swing(league, quality, 100, commitment);
    }

    /// Only the external block-hash fixture is controlled; scoring runs through finalize.
    function _rigOutcome(uint256 id, bytes32 salt, uint8 wantedTier) internal returns (uint16 feet) {
        (,, uint8 quality,,, uint64 target,,) = derby.swings(id);
        bytes32 h;
        for (uint256 i;; ++i) {
            h = keccak256(abi.encode("test outcome", id, i));
            (uint8 tier, uint16 distance) = DerbyOdds.roll(keccak256(abi.encode(salt, h)), id, quality, 100);
            if (tier == wantedTier) {
                feet = distance;
                break;
            }
        }
        vm.store(address(100), keccak256(abi.encode(uint256(target), uint256(1))), h);
        arb.setBlock(uint256(target) + 1);
    }

    function _resolveAs(uint256 id, bytes32 salt, uint8 wantedTier) internal returns (uint16 feet) {
        feet = _rigOutcome(id, salt, wantedTier);
        (uint8 actualTier, uint16 actualFeet) = derby.finalize(id, salt);
        assertEq(actualTier, wantedTier);
        assertEq(actualFeet, feet);
    }

    function _closeDay() internal {
        vm.warp((derby.currentDay() + 1) * 1 days);
        arb.setBlock(arb.arbBlockNumber() + 1_000);
    }

    function _consent(uint256 key, address player, SwarmDerby target) internal view returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(key, target.sessionDigest(player, vm.addr(key)));
        return abi.encodePacked(r, s, v);
    }

    function _assertSolvent() internal view {
        assertEq(
            token.balanceOf(address(derby)),
            derby.pot(0) + derby.pot(1) + derby.vault(0) + derby.vault(1) + derby.opsBalance()
        );
    }
}
