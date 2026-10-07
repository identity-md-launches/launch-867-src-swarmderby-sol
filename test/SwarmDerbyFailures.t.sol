// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {stdError} from "forge-std/StdError.sol";
import {SwarmDerby, IERC20, IArbSys} from "src/SwarmDerby.sol";
import {DerbyOdds} from "src/DerbyOdds.sol";
import {DerbyFixture, DerbyTestToken} from "./helpers/DerbyFixture.sol";

contract UnavailableDerbyHash {
    bool private immutable reject;

    constructor(bool reject_) {
        reject = reject_;
    }

    function arbBlockHash(uint256) external view returns (bytes32) {
        require(!reject, "hash unavailable");
        return bytes32(0);
    }
}

contract SwarmDerbyFailuresTest is DerbyFixture {
    function test_sessionPurchaseAndPermissionlessSlamEmitPlayerEvents() public {
        uint256 key = 0x5151;
        address session = vm.addr(key);
        _fund(session, 0.5 ether);
        bytes memory consent = _consent(key, ALICE, derby);
        vm.prank(ALICE);
        derby.setSession(session, consent);
        vm.expectEmit(true, true, false, true, address(derby));
        emit SwarmDerby.TurnsBought(ALICE, 1, 5, 0.5 ether, 0.2 ether);
        vm.prank(session);
        derby.buyPacks(1, 1);

        bytes32 commitment = keccak256(abi.encode(SALT, ALICE));
        vm.expectEmit(true, true, false, true, address(derby));
        emit SwarmDerby.SwingCommitted(0, ALICE, 1, 100, 100, 1_005);
        vm.prank(session);
        uint256 id = derby.swing(1, 100, 100, commitment);
        uint16 feet = _rigOutcome(id, SALT, DerbyOdds.SLAM);
        vm.expectEmit(true, true, true, true, address(derby));
        emit SwarmDerby.Dinger(ALICE, 1, START_DAY, feet);
        vm.expectEmit(true, true, false, true, address(derby));
        emit SwarmDerby.GrandSlam(id, ALICE, 1, feet, 0.005 ether);
        vm.expectEmit(true, true, false, true, address(derby));
        emit SwarmDerby.SwingResolved(id, ALICE, DerbyOdds.SLAM, feet);
        vm.prank(BOB);
        derby.finalize(id, SALT);
        assertEq(token.balanceOf(ALICE), 100.005 ether);
        assertEq(token.balanceOf(session), 0);
        assertEq(token.balanceOf(BOB), 100 ether);
        assertEq(derby.turns(1, ALICE), 4);
        assertEq(derby.turns(1, session), 0);
        _assertSolvent();
    }

    function _purchaseState(uint8 league) internal view returns (bytes32) {
        return keccak256(
            abi.encode(
                derby.turns(league, ALICE),
                derby.pot(league),
                derby.vault(league),
                derby.opsBalance(),
                derby.dayPot(league, derby.currentDay()),
                derby.openDays(league),
                token.balanceOf(ALICE),
                token.balanceOf(address(derby)),
                token.balanceOf(derby.DEAD()),
                token.allowance(ALICE, address(derby))
            )
        );
    }

    function test_failedPullsRestoreBalancesTurnsAndNewDayQueue() public {
        _buy(ALICE, 0, 2);
        _closeDay();
        for (uint256 i; i < 2; ++i) {
            token.setPullResponse(i == 0 ? DerbyTestToken.Response.False : DerbyTestToken.Response.Revert);
            bytes32 beforeState = _purchaseState(0);
            vm.prank(ALICE);
            vm.expectRevert(SwarmDerby.TransferFailed.selector);
            derby.buyPacks(0, 1);
            assertEq(_purchaseState(0), beforeState, "failed pull left accounting behind");
        }
        token.setPullResponse(DerbyTestToken.Response.Normal);
        _buy(ALICE, 0, 1);
        assertEq(derby.openDays(0).length, 2);
        _assertSolvent();
    }

    function test_insufficientAllowanceAndBalanceCannotMintTurns() public {
        vm.prank(ALICE);
        token.approve(address(derby), 0.15 ether - 1);
        bytes32 beforeState = _purchaseState(1);
        vm.prank(ALICE);
        vm.expectRevert(SwarmDerby.TransferFailed.selector);
        derby.buyTurns(1, 1);
        assertEq(_purchaseState(1), beforeState);

        vm.startPrank(ALICE);
        token.approve(address(derby), type(uint256).max);
        token.transfer(BOB, 100 ether - 0.15 ether + 1);
        vm.stopPrank();
        beforeState = _purchaseState(1);
        vm.prank(ALICE);
        vm.expectRevert(SwarmDerby.TransferFailed.selector);
        derby.buyTurns(1, 1);
        assertEq(_purchaseState(1), beforeState);
        token.mint(ALICE, 1);
        _buy(ALICE, 1, 1);
        assertEq(token.balanceOf(ALICE), 0);
        assertEq(derby.turns(1, ALICE), 1);
    }

    function test_failedBurnAlsoRollsBackSuccessfulPull() public {
        for (uint8 i = 2; i <= 4; ++i) {
            token.setResponse(derby.DEAD(), DerbyTestToken.Response(i));
            bytes32 beforeState = _purchaseState(1);
            vm.prank(ALICE);
            vm.expectRevert(SwarmDerby.TransferFailed.selector);
            derby.buyTurns(1, 1);
            assertEq(_purchaseState(1), beforeState, "pull was not rolled back with burn");
        }
    }

    function test_emptyTokenReturnDataSupportsPurchasesAndWithdrawals() public {
        token.setPullResponse(DerbyTestToken.Response.Empty);
        token.setResponse(derby.DEAD(), DerbyTestToken.Response.Empty);
        token.setResponse(BOB, DerbyTestToken.Response.Empty);
        vm.prank(ALICE);
        derby.buyPacks(1, 1);
        assertEq(token.balanceOf(ALICE), 99.5 ether);
        assertEq(token.balanceOf(derby.DEAD()), 0.2 ether);
        assertEq(derby.turns(1, ALICE), 5);
        derby.withdrawOps(BOB, 0.025 ether);
        assertEq(token.balanceOf(BOB), 100.025 ether);
        assertEq(derby.opsBalance(), 0);
        _assertSolvent();
    }

    function test_maximumCountsRevertWithoutPartialCredit() public {
        bytes32 beforeState = _purchaseState(0);
        vm.startPrank(ALICE);
        vm.expectRevert(stdError.arithmeticError);
        derby.buyTurns(0, type(uint256).max);
        vm.expectRevert(stdError.arithmeticError);
        derby.buyPacks(0, type(uint256).max);
        vm.stopPrank();
        assertEq(_purchaseState(0), beforeState);
    }

    function test_minimumPricesAndOneWeiRemainderConserveFunds() public {
        derby.setPrices(0.01 ether + 1, 0.05 ether + 1);
        _buy(ALICE, 0, 1);
        vm.prank(ALICE);
        derby.buyPacks(1, 1);
        assertEq(token.balanceOf(derby.DEAD()), 0.024 ether);
        assertEq(derby.pot(0), 0.0045 ether);
        assertEq(derby.pot(1), 0.0225 ether);
        assertEq(derby.opsBalance(), 0.003 ether + 2);
        _assertSolvent();
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_allLeagueValidatedEntryPointsRejectInvalidLeague(uint8 league) public {
        league = uint8(bound(league, 2, 255));
        vm.expectRevert(SwarmDerby.BadLeague.selector);
        derby.buyTurns(league, 1);
        vm.expectRevert(SwarmDerby.BadLeague.selector);
        derby.buyPacks(league, 1);
        vm.expectRevert(SwarmDerby.BadLeague.selector);
        derby.swing(league, 0, 0, bytes32(0));
        vm.expectRevert(SwarmDerby.BadLeague.selector);
        derby.settleNextDay(league);
        vm.expectRevert(SwarmDerby.BadLeague.selector);
        derby.nextSettlement(league);
        vm.expectRevert(SwarmDerby.BadLeague.selector);
        derby.openDays(league);
    }

    function test_nonOwnerCannotWithdrawOrNominateOwner() public {
        _buy(ALICE, 0, 10);
        vm.startPrank(BOB);
        vm.expectRevert(SwarmDerby.NotOwner.selector);
        derby.withdrawOps(BOB, 1);
        vm.expectRevert(SwarmDerby.NotOwner.selector);
        derby.transferOwnership(BOB);
        vm.expectRevert(SwarmDerby.NotOwner.selector);
        derby.setPrices(0.01 ether, 0.05 ether);
        vm.stopPrank();
        assertEq(derby.owner(), address(this));
        assertEq(derby.pendingOwner(), address(0));
        assertEq(derby.opsBalance(), 0.075 ether);
        _assertSolvent();
    }

    function test_failedOpsTransferRestoresFullClaim() public {
        _buy(ALICE, 0, 10);
        for (uint8 i = 2; i <= 4; ++i) {
            token.setResponse(BOB, DerbyTestToken.Response(i));
            vm.expectRevert(SwarmDerby.TransferFailed.selector);
            derby.withdrawOps(BOB, 0.075 ether);
            assertEq(derby.opsBalance(), 0.075 ether);
            assertEq(token.balanceOf(BOB), 100 ether);
            _assertSolvent();
        }
        token.setResponse(BOB, DerbyTestToken.Response.Normal);
        derby.withdrawOps(BOB, 0.075 ether);
        assertEq(derby.opsBalance(), 0);
        vm.expectRevert(stdError.arithmeticError);
        derby.withdrawOps(BOB, 1);
    }

    function test_failedSettlerTipRollsBackQueueAndCanBeRetried() public {
        _buy(ALICE, 0, 10);
        _resolveAs(_commit(ALICE, 0, 100, SALT), SALT, DerbyOdds.HOMER);
        _closeDay();
        token.setResponse(BOB, DerbyTestToken.Response.False);
        bytes32 beforeState = _purchaseState(0);
        vm.prank(BOB);
        vm.expectRevert(SwarmDerby.TransferFailed.selector);
        derby.settleNextDay(0);
        assertEq(_purchaseState(0), beforeState);
        assertEq(derby.settledDays(0), 0);
        assertEq(derby.rollover(0), 0);
        vm.prank(KEEPER);
        derby.settleNextDay(0);
        assertEq(derby.settledDays(0), 1);
        assertEq(token.balanceOf(KEEPER), 0.0030375 ether);
        _assertSolvent();
    }

    function test_rejectedWinnerDoesNotBlockOtherWinnersOrGetPaidTwice() public {
        _buy(ALICE, 1, 10);
        _buy(BOB, 1, 10);
        _resolveAs(_commit(ALICE, 1, 100, SALT), SALT, DerbyOdds.BOMB);
        _resolveAs(_commit(BOB, 1, 100, SALT), SALT, DerbyOdds.HOMER);
        _closeDay();
        token.setResponse(ALICE, DerbyTestToken.Response.Short);
        uint256 aliceBefore = token.balanceOf(ALICE);
        uint256 bobBefore = token.balanceOf(BOB);
        vm.prank(KEEPER);
        derby.settleNextDay(1);
        assertEq(token.balanceOf(ALICE), aliceBefore);
        assertEq(token.balanceOf(BOB) - bobBefore, 0.30223125 ether);
        assertEq(derby.rollover(1), 1.35 ether - 0.006075 ether - 0.30223125 ether);
        assertEq(derby.openDays(1).length, 0);
        token.setResponse(ALICE, DerbyTestToken.Response.Normal);
        vm.expectRevert(SwarmDerby.NothingToSettle.selector);
        derby.settleNextDay(1);
        assertEq(token.balanceOf(ALICE), aliceBefore);
        _assertSolvent();
    }

    function test_rejectedSlamStillScoresAndCannotRetryPayment() public {
        _buy(ALICE, 1, 10);
        uint256 id = _commit(ALICE, 1, 100, SALT);
        token.setResponse(ALICE, DerbyTestToken.Response.False);
        uint256 beforeBalance = token.balanceOf(ALICE);
        uint16 feet = _resolveAs(id, SALT, DerbyOdds.SLAM);
        assertEq(derby.dayScore(1, START_DAY, ALICE), feet);
        assertEq(derby.vault(1), 0.15 ether);
        assertEq(token.balanceOf(ALICE), beforeBalance);
        token.setResponse(ALICE, DerbyTestToken.Response.Normal);
        vm.expectRevert(SwarmDerby.WrongStatus.selector);
        derby.finalize(id, SALT);
        vm.expectRevert(SwarmDerby.WrongStatus.selector);
        derby.expire(id);
        _assertSolvent();
    }

    function _unavailableHash(bool reject) internal {
        _buy(ALICE, 0, 1);
        uint256 id = _commit(ALICE, 0, 100, SALT);
        address implementation = address(new UnavailableDerbyHash(reject));
        vm.mockFunction(address(100), implementation, abi.encodeWithSelector(IArbSys.arbBlockHash.selector));
        arb.setBlock(1_006);
        (uint8 tier, uint16 feet) = derby.finalize(id, SALT);
        assertEq(tier, DerbyOdds.FOUL);
        assertEq(feet, 0);
        assertEq(derby.dayScore(0, START_DAY, ALICE), 0);
        (,,,, SwarmDerby.Status status,,,) = derby.swings(id);
        assertEq(uint8(status), uint8(SwarmDerby.Status.Final));
        _assertSolvent();
    }

    function test_revertingBlockHashClosesSwingAsFoul() public {
        _unavailableHash(true);
    }

    function test_zeroBlockHashClosesSwingAsFoul() public {
        _unavailableHash(false);
    }

    function test_unknownAndWhiffSwingsCannotBeResolvedOrExpired() public {
        vm.expectRevert(SwarmDerby.WrongStatus.selector);
        derby.finalize(type(uint256).max, SALT);
        vm.expectRevert(SwarmDerby.WrongStatus.selector);
        derby.expire(type(uint256).max);
        _buy(ALICE, 0, 1);
        uint256 id = _commit(ALICE, 0, 0, bytes32(0));
        vm.expectRevert(SwarmDerby.WrongStatus.selector);
        derby.finalize(id, bytes32(0));
        vm.expectRevert(SwarmDerby.WrongStatus.selector);
        derby.expire(id);
        assertEq(derby.turns(0, ALICE), 0);
        assertEq(derby.nextSwingId(), 1);
    }

    function test_badCommitRestoresTurnCapAndId() public {
        _buy(ALICE, 0, 1);
        _closeDay();
        vm.prank(ALICE);
        vm.expectRevert(SwarmDerby.BadCommit.selector);
        derby.swing(0, 100, 100, bytes32(0));
        assertEq(derby.turns(0, ALICE), 1);
        assertEq(derby.arcadeSwings(START_DAY + 1, ALICE), 0);
        assertEq(derby.nextSwingId(), 0);
        assertEq(derby.openDays(0).length, 1);
        assertEq(derby.dayLastTarget(0, START_DAY + 1), 0);
    }

    function test_sessionConsentCannotCrossChainOrContract() public {
        uint256 key = 0x5151;
        address session = vm.addr(key);
        bytes memory consent = _consent(key, ALICE, derby);
        SwarmDerby other = new SwarmDerby(address(this), IERC20(IMD), 0.15 ether, 0.5 ether);
        vm.prank(ALICE);
        vm.expectRevert(SwarmDerby.BadSession.selector);
        other.setSession(session, consent);
        vm.chainId(4664);
        vm.prank(ALICE);
        vm.expectRevert(SwarmDerby.BadSession.selector);
        derby.setSession(session, consent);
        assertEq(derby.sessionNonce(session), 0);
        vm.chainId(4663);
        vm.prank(ALICE);
        derby.setSession(session, consent);
        assertEq(derby.sessionPlayer(session), ALICE);
    }

    function test_failedSessionReplacementPreservesExistingBinding() public {
        uint256 key = 0x5151;
        address session = vm.addr(key);
        bytes memory consent = _consent(key, ALICE, derby);
        vm.prank(ALICE);
        derby.setSession(session, consent);
        // setSession deletes the old reverse mapping before validating its replacement.
        vm.prank(ALICE);
        vm.expectRevert(SwarmDerby.BadSession.selector);
        derby.setSession(vm.addr(0x5152), new bytes(64));
        assertEq(derby.sessionOf(ALICE), session);
        assertEq(derby.sessionPlayer(session), ALICE);
        assertEq(derby.sessionNonce(session), 1);
        vm.prank(BOB);
        vm.expectRevert(SwarmDerby.BadSession.selector);
        derby.leaveSession();
        assertEq(derby.playerOf(session), ALICE);
    }

    function test_malleableAndInvalidVSessionSignaturesRejected() public {
        uint256 key = 0x5151;
        address session = vm.addr(key);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(key, derby.sessionDigest(ALICE, session));
        uint256 order = 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEBAAEDCE6AF48A03BBFD25E8CD0364141;
        vm.startPrank(ALICE);
        vm.expectRevert(SwarmDerby.BadSession.selector);
        derby.setSession(session, abi.encodePacked(r, bytes32(order - uint256(s)), uint8(v == 27 ? 28 : 27)));
        vm.expectRevert(SwarmDerby.BadSession.selector);
        derby.setSession(session, abi.encodePacked(r, s, uint8(29)));
        assertEq(derby.sessionNonce(session), 0);
        derby.setSession(session, abi.encodePacked(r, s, uint8(v - 27)));
        vm.stopPrank();
        assertEq(derby.sessionPlayer(session), ALICE);
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_purchaseRoundingConservesEveryWei(uint256 single, uint256 pack, uint256 n, bool packs) public {
        single = bound(single, 0.01 ether, 1 ether);
        pack = bound(pack, 0.05 ether, 5 ether);
        n = bound(n, 1, 100);
        derby.setPrices(single, pack);
        uint256 cost = n * (packs ? pack : single);
        _fund(ALICE, cost);
        uint256 beforeBalance = token.balanceOf(ALICE);
        vm.prank(ALICE);
        if (packs) derby.buyPacks(0, n);
        else derby.buyTurns(0, n);
        assertEq(beforeBalance - token.balanceOf(ALICE), cost);
        assertEq(derby.turns(0, ALICE), n * (packs ? 5 : 1));
        _assertSolvent();
        assertEq(token.balanceOf(address(derby)) + token.balanceOf(derby.DEAD()), cost);
        // Floor rounding is within one wei of the specified fractional share.
        assertLe(token.balanceOf(derby.DEAD()) * 5, cost * 2);
        assertLt(cost * 2 - token.balanceOf(derby.DEAD()) * 5, 5);
        assertLe(derby.pot(0) * 20, cost * 9);
        assertLt(cost * 9 - derby.pot(0) * 20, 20);
        assertLe(derby.vault(0) * 10, cost);
        assertLt(cost - derby.vault(0) * 10, 10);
        assertEq(derby.dayPot(0, START_DAY), derby.pot(0));
        assertEq(derby.pot(1) + derby.vault(1), 0);
    }
}
