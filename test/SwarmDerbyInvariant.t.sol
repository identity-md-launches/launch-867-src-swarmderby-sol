// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {SwarmDerby} from "src/SwarmDerby.sol";
import {DerbyOdds} from "src/DerbyOdds.sol";
import {MockArbSys} from "./SwarmDerby.t.sol";
import {DerbyFixture, DerbyTestToken} from "./helpers/DerbyFixture.sol";

/// @dev All game state is reached through the production ABI. Ghosts derive from actions,
/// explicit economic terms and observed outcomes, never from writing Derby storage.
contract DerbySequenceHandler is Test {
    uint256 public constant PLAYERS = 12;
    address public constant KEEPER = address(0xCEEE);
    address public constant OPS = address(0x0F55);
    SwarmDerby public immutable derby;
    DerbyTestToken public immutable token;
    MockArbSys public immutable arb;
    address[24] public actors;
    bool[12] public boundSession;
    uint256[12] public nonces;

    struct RecordedSwing {
        address player;
        uint8 league;
        uint8 quality;
        uint8 velo;
        uint64 target;
        uint32 day;
        bytes32 salt;
        bool finished;
    }
    RecordedSwing[] public recorded;
    mapping(uint8 => mapping(address => uint256)) public credits;
    mapping(uint256 => mapping(address => uint256)) public used;
    mapping(uint8 => mapping(uint256 => mapping(address => uint256))) public scores;
    mapping(uint8 => mapping(uint256 => uint256)) public dayFunds;
    mapping(uint8 => mapping(uint256 => uint256)) public lastTarget;
    uint256[][2] internal daysSeen;
    uint256[2] public head;
    uint256[2] public potDeposits;
    uint256[2] public vaultDeposits;
    uint256[2] public settlementPaid;
    uint256[2] public slamPaid;
    uint256 public deposits;
    uint256 public donated;
    uint256 public opsEarned;
    uint256 public opsWithdrawn;
    // Success counts make it possible to prove the handler reaches money-moving paths.
    uint256 public purchases;
    uint256 public resolutions;
    uint256 public expirations;
    uint256 public settlements;

    constructor(SwarmDerby derby_, DerbyTestToken token_, MockArbSys arb_) {
        derby = derby_;
        token = token_;
        arb = arb_;
        for (uint256 i; i < PLAYERS; ++i) {
            actors[i] = address(uint160(0x10000 + i));
            actors[i + PLAYERS] = vm.addr(0x5100 + i);
        }
        for (uint256 i; i < actors.length; ++i) {
            token.mint(actors[i], 10_000 ether);
            vm.prank(actors[i]);
            token.approve(address(derby), type(uint256).max);
        }
    }

    function _player(uint256 actorIndex) internal view returns (address) {
        if (actorIndex >= PLAYERS && boundSession[actorIndex - PLAYERS]) return actors[actorIndex - PLAYERS];
        return actors[actorIndex];
    }

    function _mark(uint8 league, uint256 day) internal {
        uint256 n = daysSeen[league].length;
        if (n == 0 || daysSeen[league][n - 1] != day) daysSeen[league].push(day);
    }

    function purchase(uint256 actorSeed, uint8 league, uint256 count, bool packs) public {
        uint256 index = actorSeed % actors.length;
        league %= 2;
        count = bound(count, 1, 10);
        uint256 cost = count * (packs ? 0.5 ether : 0.15 ether);
        address player = _player(index);
        vm.prank(actors[index]);
        if (packs) derby.buyPacks(league, count);
        else derby.buyTurns(league, count);
        credits[league][player] += count * (packs ? 5 : 1);
        deposits += cost;
        potDeposits[league] += cost * 9 / 20;
        vaultDeposits[league] += cost / 10;
        opsEarned += cost / 20;
        uint256 day = block.timestamp / 1 days;
        dayFunds[league][day] += cost * 9 / 20;
        _mark(league, day);
        ++purchases;
    }

    function commitSwing(uint256 actorSeed, uint8 league, uint8 quality, uint8 velo, bytes32 salt) public {
        uint256 index = actorSeed % actors.length;
        address player = _player(index);
        league %= 2;
        quality = uint8(bound(quality, 0, 100));
        velo = uint8(bound(velo, 0, 100));
        uint256 day = block.timestamp / 1 days;
        bytes32 commitment = keccak256(abi.encode(salt, player));
        if (credits[league][player] == 0) {
            vm.prank(actors[index]);
            vm.expectRevert(SwarmDerby.NoTurns.selector);
            derby.swing(league, quality, velo, commitment);
            return;
        }
        if (league == 0 && used[day][player] == 20) {
            vm.prank(actors[index]);
            vm.expectRevert(SwarmDerby.DailyCapReached.selector);
            derby.swing(league, quality, velo, commitment);
            return;
        }
        vm.prank(actors[index]);
        uint256 id = derby.swing(league, quality, velo, commitment);
        assertEq(id, recorded.length, "swing ids must never be reused");
        --credits[league][player];
        if (league == 0) ++used[day][player];
        uint64 target = quality == 0 ? 0 : uint64(arb.arbBlockNumber() + 5);
        recorded.push(RecordedSwing(player, league, quality, velo, target, uint32(day), salt, quality == 0));
        if (quality > 0) {
            _mark(league, day);
            lastTarget[league][day] = target;
        }
    }

    function _pending(uint256 seed) internal view returns (uint256 id, bool exists) {
        uint256 n = recorded.length;
        if (n == 0) return (0, false);
        for (uint256 i; i < n; ++i) {
            id = (seed % n + i) % n;
            if (!recorded[id].finished) return (id, true);
        }
    }

    function reveal(uint256 seed) public {
        (uint256 id, bool exists) = _pending(seed);
        if (!exists) return;
        RecordedSwing storage s = recorded[id];
        uint256 current = arb.arbBlockNumber();
        if (current <= s.target) arb.setBlock(uint256(s.target) + 1);
        uint256 vaultBefore = vaultDeposits[s.league] - slamPaid[s.league];
        uint256 balanceBefore = token.balanceOf(s.player);
        vm.prank(KEEPER); // Permissionless reveal must still pay the original player.
        (uint8 tier, uint16 feet) = derby.finalize(id, s.salt);
        uint256 payout;
        if (tier == DerbyOdds.SLAM && token.responseTo(s.player) == DerbyTestToken.Response.Normal) {
            payout = vaultBefore / 10;
        }
        assertEq(token.balanceOf(s.player) - balanceBefore, payout, "slam paid wrong beneficiary or amount");
        slamPaid[s.league] += payout;
        if (arb.arbBlockNumber() > uint256(s.target) + 255) {
            assertEq(tier, DerbyOdds.FOUL);
            assertEq(feet, 0);
        }
        if (tier >= DerbyOdds.HOMER) {
            uint256 old = scores[s.league][s.day][s.player];
            scores[s.league][s.day][s.player] = s.league == 1 ? old + feet : (old > feet ? old : feet);
        }
        s.finished = true;
        ++resolutions;
        vm.expectRevert(SwarmDerby.WrongStatus.selector);
        derby.finalize(id, s.salt);
        vm.expectRevert(SwarmDerby.WrongStatus.selector);
        derby.expire(id);
    }

    function expireSwing(uint256 seed) public {
        (uint256 id, bool exists) = _pending(seed);
        if (!exists) return;
        RecordedSwing storage s = recorded[id];
        uint256 end = uint256(s.target) + 255;
        if (arb.arbBlockNumber() <= end) arb.setBlock(end + 1);
        vm.prank(KEEPER);
        derby.expire(id);
        s.finished = true;
        ++expirations;
        vm.expectRevert(SwarmDerby.WrongStatus.selector);
        derby.expire(id);
    }

    function advance(uint256 secondsSeed, uint256 blocksSeed) public {
        vm.warp(block.timestamp + bound(secondsSeed, 1, 2 days));
        arb.setBlock(arb.arbBlockNumber() + bound(blocksSeed, 1, 300));
    }

    function settle(uint8 league) public {
        league %= 2;
        if (head[league] == daysSeen[league].length) {
            vm.expectRevert(SwarmDerby.NothingToSettle.selector);
            derby.settleNextDay(league);
            return;
        }
        uint256 day = daysSeen[league][head[league]];
        if (day >= block.timestamp / 1 days || arb.arbBlockNumber() <= lastTarget[league][day] + 255) {
            vm.expectRevert(SwarmDerby.DayNotOver.selector);
            derby.settleNextDay(league);
            return;
        }
        uint256 amount = dayFunds[league][day] + derby.rollover(league);
        (address[] memory winners,) = derby.board(league, day);
        uint256 count = winners.length < 3 ? winners.length : 3;
        uint256 tip = count == 0 ? 0 : (amount * 9 / 10) / 200;
        uint256 distributable = amount * 9 / 10 - tip;
        uint256[3] memory balances;
        uint256[3] memory shares = [uint256(60), 25, 15];
        for (uint256 i; i < count; ++i) {
            balances[i] = token.balanceOf(winners[i]);
        }
        uint256 keeperBefore = token.balanceOf(KEEPER);
        uint256 paid = tip;
        vm.prank(KEEPER);
        derby.settleNextDay(league);
        assertEq(token.balanceOf(KEEPER) - keeperBefore, tip);
        for (uint256 i; i < count; ++i) {
            uint256 prize =
                token.responseTo(winners[i]) == DerbyTestToken.Response.Normal ? distributable * shares[i] / 100 : 0;
            assertEq(token.balanceOf(winners[i]) - balances[i], prize);
            paid += prize;
        }
        assertEq(derby.rollover(league), amount - paid);
        dayFunds[league][day] = 0;
        settlementPaid[league] += paid;
        ++head[league];
        ++settlements;
    }

    function withdraw(uint256 amount) public {
        amount = bound(amount, 0, opsEarned - opsWithdrawn);
        uint256 beforeBalance = token.balanceOf(OPS);
        derby.withdrawOps(OPS, amount); // The handler is the explicitly appointed owner.
        assertEq(token.balanceOf(OPS) - beforeBalance, amount);
        opsWithdrawn += amount;
    }

    function donate(uint256 actorSeed, uint256 amount) public {
        amount = bound(amount, 1, 1 ether);
        vm.prank(actors[actorSeed % actors.length]);
        token.transfer(address(derby), amount);
        donated += amount;
    }

    function toggleRecipient(uint256 actorSeed, bool reject) public {
        token.setResponse(
            actors[actorSeed % actors.length], reject ? DerbyTestToken.Response.False : DerbyTestToken.Response.Normal
        );
    }

    function toggleSession(uint256 playerSeed, bool leaveByKey) public {
        uint256 i = playerSeed % PLAYERS;
        address key = actors[i + PLAYERS];
        if (boundSession[i]) {
            if (leaveByKey) {
                vm.prank(key);
                derby.leaveSession();
            } else {
                vm.prank(actors[i]);
                derby.setSession(address(0), "");
            }
        } else {
            (uint8 v, bytes32 r, bytes32 s) = vm.sign(0x5100 + i, derby.sessionDigest(actors[i], key));
            vm.prank(actors[i]);
            derby.setSession(key, abi.encodePacked(r, s, v));
            ++nonces[i];
        }
        boundSession[i] = !boundSession[i];
    }

    function assertAccounting() public view {
        uint256 held = token.balanceOf(address(derby));
        uint256 liabilities = derby.opsBalance();
        uint256 prizes;
        for (uint8 l; l < 2; ++l) {
            assertEq(derby.vault(l) + slamPaid[l], vaultDeposits[l], "league vault conservation");
            assertEq(derby.pot(l) + settlementPaid[l], potDeposits[l], "league pot conservation");
            liabilities += derby.pot(l) + derby.vault(l);
            prizes += settlementPaid[l] + slamPaid[l];
        }
        assertEq(derby.opsBalance() + opsWithdrawn, opsEarned, "owner exceeded ops allocation");
        assertEq(held, liabilities + donated, "custody differs from liabilities plus unsolicited tokens");
        assertEq(token.balanceOf(derby.DEAD()), deposits * 2 / 5, "burned share changed");
        assertEq(
            deposits + donated, held + prizes + opsWithdrawn + token.balanceOf(derby.DEAD()), "value lost or created"
        );
    }

    function assertPlayersAndSwings() public view {
        for (uint256 i; i < actors.length; ++i) {
            address actor = actors[i];
            assertEq(derby.turns(0, actor), credits[0][actor]);
            assertEq(derby.turns(1, actor), credits[1][actor]);
            assertEq(derby.playerOf(actor), _player(i));
            uint256 day = block.timestamp / 1 days;
            assertEq(derby.arcadeSwings(day, actor), used[day][actor]);
            assertLe(used[day][actor], 20);
            assertEq(derby.arcadeSwingsLeft(actor), 20 - used[day][actor]);
            if (i < PLAYERS) {
                assertEq(derby.sessionOf(actor), boundSession[i] ? actors[i + PLAYERS] : address(0));
                assertEq(derby.sessionPlayer(actors[i + PLAYERS]), boundSession[i] ? actor : address(0));
                assertEq(derby.sessionNonce(actors[i + PLAYERS]), nonces[i]);
            }
        }
        assertEq(derby.nextSwingId(), recorded.length);
        for (uint256 i; i < recorded.length; ++i) {
            RecordedSwing storage expected = recorded[i];
            (
                address player,
                uint8 league,
                uint8 quality,
                uint8 velo,
                SwarmDerby.Status status,
                uint64 target,
                bytes32 commitment,
                uint32 day
            ) = derby.swings(i);
            assertEq(player, expected.player);
            assertEq(league, expected.league);
            assertEq(quality, expected.quality);
            assertEq(velo, expected.velo);
            assertEq(target, expected.target);
            assertEq(day, expected.day);
            assertEq(commitment, quality == 0 ? bytes32(0) : keccak256(abi.encode(expected.salt, player)));
            assertEq(uint8(status), uint8(expected.finished ? SwarmDerby.Status.Final : SwarmDerby.Status.Committed));
        }
    }

    function assertQueuesAndBoards() public view {
        for (uint8 l; l < 2; ++l) {
            uint256[] memory open = derby.openDays(l);
            assertEq(derby.settledDays(l), head[l]);
            assertEq(open.length, daysSeen[l].length - head[l]);
            uint256 remaining = derby.rollover(l);
            for (uint256 d; d < daysSeen[l].length; ++d) {
                uint256 day = daysSeen[l][d];
                assertEq(derby.dayPot(l, day), dayFunds[l][day]);
                assertEq(derby.dayLastTarget(l, day), lastTarget[l][day]);
                remaining += dayFunds[l][day];
                if (d >= head[l]) assertEq(open[d - head[l]], day, "queue order changed");
                (address[] memory board, uint256[] memory points) = derby.board(l, day);
                assertLe(board.length, 10);
                for (uint256 i; i < board.length; ++i) {
                    assertGt(points[i], 0);
                    assertEq(points[i], scores[l][day][board[i]]);
                    if (i > 0) assertGe(points[i - 1], points[i]);
                    for (uint256 j; j < i; ++j) {
                        assertTrue(board[j] != board[i], "duplicate leader");
                    }
                }
                uint256 listed;
                for (uint256 i; i < actors.length; ++i) {
                    uint256 expected = scores[l][day][actors[i]];
                    assertEq(derby.dayScore(l, day, actors[i]), expected, "score changed outside successful reveal");
                    bool found;
                    for (uint256 j; j < board.length; ++j) {
                        if (board[j] == actors[i]) found = true;
                    }
                    if (found) ++listed;
                    else if (board.length < 10) assertEq(expected, 0, "missing scorer");
                    else assertLe(expected, points[9], "better player missing from full board");
                }
                assertEq(listed, board.length, "untracked beneficiary on board");
            }
            assertEq(derby.pot(l), remaining, "pot differs from open days plus rollover");
        }
    }
}

/// forge-config: default.invariant.runs = 256
/// forge-config: default.invariant.depth = 64
/// forge-config: default.invariant.fail-on-revert = true
contract SwarmDerbyInvariantTest is DerbyFixture {
    DerbySequenceHandler internal handler;

    function setUp() public override {
        super.setUp();
        handler = new DerbySequenceHandler(derby, token, arb);
        derby.transferOwnership(address(handler));
        vm.prank(address(handler));
        derby.acceptOwnership();
        // Start with real purchases so random swings and withdrawals can reach useful states.
        for (uint256 i; i < 12; ++i) {
            handler.purchase(i, 0, 4, true);
            handler.purchase(i, 1, 4, true);
        }
        bytes4[] memory selectors = new bytes4[](10);
        selectors[0] = handler.purchase.selector;
        selectors[1] = handler.commitSwing.selector;
        selectors[2] = handler.reveal.selector;
        selectors[3] = handler.expireSwing.selector;
        selectors[4] = handler.advance.selector;
        selectors[5] = handler.settle.selector;
        selectors[6] = handler.withdraw.selector;
        selectors[7] = handler.donate.selector;
        selectors[8] = handler.toggleRecipient.selector;
        selectors[9] = handler.toggleSession.selector;
        targetContract(address(handler));
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
    }

    function invariant_custodyCreditsQueuesAndFinality() public view {
        handler.assertAccounting();
        handler.assertPlayersAndSwings();
        handler.assertQueuesAndBoards();
    }

    /// Every generated history must still permit closing all swings/days and withdrawing all ops.
    function afterInvariant() public {
        for (uint256 i; i < derby.nextSwingId(); ++i) {
            handler.expireSwing(i);
        }
        handler.advance(2 days, 300);
        for (uint8 l; l < 2; ++l) {
            while (derby.openDays(l).length > 0) {
                uint256 beforeHead = derby.settledDays(l);
                handler.settle(l);
                assertEq(derby.settledDays(l), beforeHead + 1, "settlement queue cannot be drained");
            }
            assertEq(derby.pot(l), derby.rollover(l));
        }
        handler.withdraw(handler.opsEarned() - handler.opsWithdrawn());
        assertEq(derby.opsBalance(), 0);
        invariant_custodyCreditsQueuesAndFinality();
    }

    /// Exercises every handler, including actual winner payments, before trusting the random campaign.
    function test_handlerReachesPayoutsFailuresSessionsAndExpiry() public {
        handler.toggleSession(0, false);
        handler.purchase(12, 0, 1, false);
        handler.commitSwing(12, 0, 100, 100, SALT);
        // Select an external hash producing a slam; the handler still performs and checks the reveal.
        bytes32 h;
        for (uint256 i;; ++i) {
            h = keccak256(abi.encode("handler slam", i));
            (uint8 tier,) = DerbyOdds.roll(keccak256(abi.encode(SALT, h)), 0, 100, 100);
            if (tier == DerbyOdds.SLAM) break;
        }
        vm.store(address(100), keccak256(abi.encode(uint256(1_005), uint256(1))), h);
        handler.reveal(0);
        assertGt(handler.slamPaid(0), 0);
        handler.toggleRecipient(0, true);
        handler.commitSwing(0, 1, 100, 100, SALT);
        handler.expireSwing(1);
        handler.toggleSession(0, true);
        handler.donate(1, 1);
        handler.withdraw(type(uint256).max);
        handler.advance(1 days, 300);
        handler.settle(0); // Blocked first prize rolls over, but the keeper is paid.
        handler.settle(1); // Empty board rolls over without a tip.
        handler.settle(1); // Expected NothingToSettle is checked by the handler.
        assertEq(handler.resolutions(), 1);
        assertEq(handler.expirations(), 1);
        assertEq(handler.settlements(), 2);
        assertGt(handler.settlementPaid(0), 0);
        assertEq(handler.settlementPaid(1), 0);
        invariant_custodyCreditsQueuesAndFinality();
    }
}
