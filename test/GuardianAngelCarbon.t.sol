// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import "forge-std/Test.sol";
import "../src/GuardianAngelCarbon.sol";

contract GuardianAngelCarbonTest is Test {
    GuardianAngelCarbon public angel;
    address public owner;
    address public guardian;
    address public verifier;
    address public offsetRecipient;
    address public user;
    address public other;

    uint256 public constant INITIAL_BPS = 500; // 5%

    event OwnershipTransferStarted(address indexed previousOwner, address indexed newOwner);
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);
    event GuardianRotated(address indexed previous, address indexed newGuardian);
    event GuardianRotationCancelled(address indexed cancelledBy);
    event GuardianRotationInitiated(address indexed current, address indexed pending, uint256 unlockTime);
    event OffsetBpsUpdated(uint256 newBps);
    event OffsetRecipientUpdated(address indexed newRecipient);
    event VerifierUpdated(address indexed newVerifier);
    event AwardCreated(uint256 indexed awardId, address indexed recipient, uint256 amount, address indexed creator);
    event AwardVerified(uint256 indexed awardId, address indexed verifier);
    event AwardDistributed(uint256 indexed awardId, address indexed recipient, uint256 amount, uint256 offsetAmount, address indexed offsetRecipient);
    event Paused(address indexed triggeredBy);
    event Unpaused(address indexed triggeredBy);
    event AllowedContractUpdated(address indexed contractAddr, bool status);
    event ChangeProposed(bytes32 indexed proposalId, address indexed proposer, uint256 deadline);
    event ChangeApproved(bytes32 indexed proposalId, address indexed approver);
    event ChangeExecuted(bytes32 indexed proposalId, bytes32 indexed parameter, uint256 value);

    function setUp() public {
        owner = address(this);
        guardian = makeAddr("guardian");
        verifier = makeAddr("verifier");
        offsetRecipient = makeAddr("offsetRecipient");
        user = makeAddr("user");
        other = makeAddr("other");

        vm.prank(owner);
        angel = new GuardianAngelCarbon(
            guardian,
            verifier,
            offsetRecipient,
            INITIAL_BPS
        );
    }

    // ================================================================
    // 1. Deployment & Constructor Validation
    // ================================================================

    function test_Deployment() public view {
        assertEq(angel.owner(), owner);
        assertEq(angel.guardian(), guardian);
        assertEq(angel.verifier(), verifier);
        assertEq(angel.offsetRecipient(), offsetRecipient);
        assertEq(angel.offsetBps(), INITIAL_BPS);
        assertFalse(angel.paused());
        assertEq(angel.awardCount(), 0);
    }

    function test_Deployment_Reverts_ZeroGuardian() public {
        vm.prank(owner);
        vm.expectRevert(GuardianAngelCarbon.ZeroAddress.selector);
        new GuardianAngelCarbon(address(0), verifier, offsetRecipient, INITIAL_BPS);
    }

    function test_Deployment_Reverts_ZeroVerifier() public {
        vm.prank(owner);
        vm.expectRevert(GuardianAngelCarbon.ZeroAddress.selector);
        new GuardianAngelCarbon(guardian, address(0), offsetRecipient, INITIAL_BPS);
    }

    function test_Deployment_Reverts_ZeroOffsetRecipient() public {
        vm.prank(owner);
        vm.expectRevert(GuardianAngelCarbon.ZeroAddress.selector);
        new GuardianAngelCarbon(guardian, verifier, address(0), INITIAL_BPS);
    }

    function test_Deployment_Reverts_InvalidBps() public {
        vm.prank(owner);
        vm.expectRevert(GuardianAngelCarbon.InvalidBasisPoints.selector);
        new GuardianAngelCarbon(guardian, verifier, offsetRecipient, 10001);
    }

    // ================================================================
    // 2. Two-Step Ownership Transfer
    // ================================================================

    function test_OwnershipTransfer() public {
        address newOwner = makeAddr("newOwner");
        vm.expectEmit(true, true, false, false);
        emit OwnershipTransferStarted(owner, newOwner);
        angel.transferOwnership(newOwner);

        assertEq(angel.pendingOwner(), newOwner);
        assertEq(angel.owner(), owner);

        vm.prank(newOwner);
        vm.expectEmit(true, true, false, false);
        emit OwnershipTransferred(owner, newOwner);
        angel.acceptOwnership();

        assertEq(angel.owner(), newOwner);
        assertEq(angel.pendingOwner(), address(0));
    }

    function test_OwnershipTransfer_Cancel() public {
        address newOwner = makeAddr("newOwner");
        angel.transferOwnership(newOwner);
        angel.cancelOwnershipTransfer();
        assertEq(angel.pendingOwner(), address(0));
    }

    function test_OwnershipTransfer_Reverts_NotPending() public {
        vm.prank(other);
        vm.expectRevert(GuardianAngelCarbon.NotPendingOwner.selector);
        angel.acceptOwnership();
    }

    // ================================================================
    // 3. Guardian Rotation (24h timelock)
    // ================================================================

    function test_GuardianRotation() public {
        address newGuardian = makeAddr("newGuardian");
        uint256 unlock = block.timestamp + 24 hours;

        vm.expectEmit(true, true, false, true);
        emit GuardianRotationInitiated(guardian, newGuardian, unlock);
        angel.initiateGuardianRotation(newGuardian);

        assertEq(angel.pendingGuardian(), newGuardian);
        assertEq(angel.guardianRotationUnlock(), unlock);

        vm.expectRevert(GuardianAngelCarbon.TimelockActive.selector);
        angel.finalizeGuardianRotation();

        vm.warp(block.timestamp + 24 hours + 1);
        vm.expectEmit(true, true, false, false);
        emit GuardianRotated(guardian, newGuardian);
        angel.finalizeGuardianRotation();

        assertEq(angel.guardian(), newGuardian);
        assertEq(angel.pendingGuardian(), address(0));
        assertEq(angel.guardianRotationUnlock(), 0);
    }

    function test_GuardianRotation_Cancel() public {
        address newGuardian = makeAddr("newGuardian");
        angel.initiateGuardianRotation(newGuardian);

        vm.expectEmit(true, false, false, false);
        emit GuardianRotationCancelled(owner);
        angel.cancelGuardianRotation();

        assertEq(angel.pendingGuardian(), address(0));
        assertEq(angel.guardianRotationUnlock(), 0);
    }

    // ================================================================
    // 4. Multi-Sig Parameter Proposal System (2-day timelock)
    // ================================================================

    function test_ProposalSystem_OffsetBps() public {
        bytes32 param = keccak256("offsetBps");
        uint256 newValue = 1000;
        bytes32 proposalId = keccak256(abi.encodePacked(param, newValue, block.timestamp));

        vm.prank(owner);
        vm.expectEmit(true, true, false, true);
        emit ChangeProposed(proposalId, owner, block.timestamp + angel.CHANGE_TIMELOCK());
        angel.proposeChange(param, newValue);

        vm.prank(guardian);
        vm.expectEmit(true, false, false, false);
        emit ChangeApproved(proposalId, guardian);
        angel.approveProposal(proposalId);

        vm.expectRevert(GuardianAngelCarbon.TimelockActive.selector);
        angel.executeProposal(proposalId);

        vm.warp(block.timestamp + angel.CHANGE_TIMELOCK() + 1);

        vm.prank(owner);
        vm.expectEmit(true, true, false, false);
        emit ChangeExecuted(proposalId, param, newValue);
        vm.expectEmit(true, false, false, false);
        emit OffsetBpsUpdated(newValue);
        angel.executeProposal(proposalId);

        assertEq(angel.offsetBps(), newValue);
    }

    function test_ProposalSystem_OffsetRecipient() public {
        address newOffset = makeAddr("newOffset");
        bytes32 param = keccak256("offsetRecipient");
        uint256 newValue = uint256(uint160(newOffset));
        bytes32 proposalId = keccak256(abi.encodePacked(param, newValue, block.timestamp));

        vm.prank(owner);
        angel.proposeChange(param, newValue);
        vm.prank(guardian);
        angel.approveProposal(proposalId);
        vm.warp(block.timestamp + angel.CHANGE_TIMELOCK() + 1);

        vm.prank(owner);
        vm.expectEmit(true, false, false, false);
        emit OffsetRecipientUpdated(newOffset);
        angel.executeProposal(proposalId);

        assertEq(angel.offsetRecipient(), newOffset);
    }

    function test_ProposalSystem_Verifier() public {
        address newVerifier = makeAddr("newVerifier");
        bytes32 param = keccak256("verifier");
        uint256 newValue = uint256(uint160(newVerifier));
        bytes32 proposalId = keccak256(abi.encodePacked(param, newValue, block.timestamp));

        vm.prank(owner);
        angel.proposeChange(param, newValue);
        vm.prank(guardian);
        angel.approveProposal(proposalId);
        vm.warp(block.timestamp + angel.CHANGE_TIMELOCK() + 1);

        vm.prank(owner);
        vm.expectEmit(true, false, false, false);
        emit VerifierUpdated(newVerifier);
        angel.executeProposal(proposalId);

        assertEq(angel.verifier(), newVerifier);
    }

    function test_ProposalSystem_Cancel() public {
        bytes32 param = keccak256("offsetBps");
        uint256 newValue = 1000;
        bytes32 proposalId = keccak256(abi.encodePacked(param, newValue, block.timestamp));

        vm.prank(owner);
        angel.proposeChange(param, newValue);
        vm.prank(guardian);
        angel.approveProposal(proposalId);

        vm.prank(owner);
        angel.cancelProposal(proposalId);
        ( , , uint256 deadline, bool executed, , ) = angel.proposals(proposalId);
        assertEq(deadline, 0);
        assertFalse(executed);
    }

    function test_ProposalSystem_Reverts_NotApproved() public {
        bytes32 param = keccak256("offsetBps");
        uint256 newValue = 1000;
        bytes32 proposalId = keccak256(abi.encodePacked(param, newValue, block.timestamp));

        vm.prank(owner);
        angel.proposeChange(param, newValue);

        vm.warp(block.timestamp + angel.CHANGE_TIMELOCK() + 1);
        vm.prank(owner);
        vm.expectRevert(GuardianAngelCarbon.ChangeNotApproved.selector);
        angel.executeProposal(proposalId);
    }

    // ================================================================
    // 5. Award Lifecycle (Create → Verify → Distribute)
    // ================================================================

    function test_AwardLifecycle() public {
        uint256 amount = 1 ether;
        uint256 offsetAmount = (amount * INITIAL_BPS) / 10000;
        uint256 recipientAmount = amount - offsetAmount;

        vm.prank(guardian);
        vm.expectEmit(true, true, true, true);
        emit AwardCreated(0, user, amount, guardian);
        angel.createAward(user, amount);

        (address recipient, uint256 amt, bool verified, bool distributed, ) = angel.awards(0);
        assertEq(recipient, user);
        assertEq(amt, amount);
        assertFalse(verified);
        assertFalse(distributed);

        vm.prank(verifier);
        vm.expectEmit(true, true, false, false);
        emit AwardVerified(0, verifier);
        angel.verifyAward(0);
        (, , verified, , ) = angel.awards(0);
        assertTrue(verified);

        vm.deal(address(angel), amount);

        uint256 recipientBalanceBefore = user.balance;
        uint256 offsetBalanceBefore = offsetRecipient.balance;

        vm.expectEmit(true, true, true, true);
        emit AwardDistributed(0, user, amount, offsetAmount, offsetRecipient);
        angel.distributeAward(0);

        assertEq(user.balance, recipientBalanceBefore + recipientAmount);
        assertEq(offsetRecipient.balance, offsetBalanceBefore + offsetAmount);

        (, , , distributed, ) = angel.awards(0);
        assertTrue(distributed);
    }

    function test_AwardLifecycle_Reverts_NotVerified() public {
        vm.prank(guardian);
        angel.createAward(user, 1 ether);
        vm.deal(address(angel), 1 ether);
        vm.expectRevert(GuardianAngelCarbon.AwardNotVerified.selector);
        angel.distributeAward(0);
    }

    function test_AwardLifecycle_Reverts_InsufficientFunds() public {
        vm.prank(guardian);
        angel.createAward(user, 1 ether);
        vm.prank(verifier);
        angel.verifyAward(0);
        vm.expectRevert(GuardianAngelCarbon.InsufficientFunds.selector);
        angel.distributeAward(0);
    }

    // ================================================================
    // 6. Contract Filtering (Security Boundary)
    // ================================================================

    function test_ContractFiltering_Reverts_Unwhitelisted() public {
        DummyContract dummy = new DummyContract();
        vm.prank(guardian);
        vm.expectRevert(GuardianAngelCarbon.RecipientIsContractNotAllowed.selector);
        angel.createAward(address(dummy), 1 ether);
    }

    function test_ContractFiltering_Whitelisted() public {
        DummyContract dummy = new DummyContract();
        address dummyAddr = address(dummy);

        vm.prank(owner);
        vm.expectEmit(true, false, false, false);
        emit AllowedContractUpdated(dummyAddr, true);
        angel.setAllowedContract(dummyAddr, true);

        vm.prank(guardian);
        angel.createAward(dummyAddr, 1 ether);

        (address recipient, , , , ) = angel.awards(0);
        assertEq(recipient, dummyAddr);
    }

    // ================================================================
    // 7. Emergency Circuit Breaker (Pause)
    // ================================================================

    function test_Pause() public {
        vm.prank(owner);
        vm.expectEmit(true, false, false, false);
        emit Paused(owner);
        angel.pause();
        assertTrue(angel.paused());

        vm.prank(guardian);
        vm.expectRevert(GuardianAngelCarbon.NotOwner.selector);
        angel.unpause();

        vm.prank(owner);
        vm.expectEmit(true, false, false, false);
        emit Unpaused(owner);
        angel.unpause();
        assertFalse(angel.paused());

        vm.prank(guardian);
        angel.pause();
        assertTrue(angel.paused());
    }

    function test_Pause_BlocksAwardCreation() public {
        vm.prank(owner);
        angel.pause();

        vm.prank(guardian);
        vm.expectRevert(GuardianAngelCarbon.ContractPaused.selector);
        angel.createAward(user, 1 ether);
    }

    function test_Pause_BlocksVerification() public {
        vm.prank(guardian);
        angel.createAward(user, 1 ether);

        vm.prank(owner);
        angel.pause();

        vm.prank(verifier);
        vm.expectRevert(GuardianAngelCarbon.ContractPaused.selector);
        angel.verifyAward(0);
    }

    function test_Pause_BlocksProposal() public {
        vm.prank(owner);
        angel.pause();

        vm.prank(owner);
        vm.expectRevert(GuardianAngelCarbon.ContractPaused.selector);
        angel.proposeChange(keccak256("offsetBps"), 1000);
    }

    // ================================================================
    // 8. Carbon Offset Math Accuracy
    // ================================================================

    function test_OffsetMath() public {
        // Change offsetBps to 200 (2%)
        bytes32 param = keccak256("offsetBps");
        uint256 newBps = 200;
        bytes32 proposalId = keccak256(abi.encodePacked(param, newBps, block.timestamp));

        vm.prank(owner);
        angel.proposeChange(param, newBps);
        vm.prank(guardian);
        angel.approveProposal(proposalId);
        vm.warp(block.timestamp + angel.CHANGE_TIMELOCK() + 1);
        vm.prank(owner);
        angel.executeProposal(proposalId);

        uint256 amount = 1234567890 wei;
        uint256 expectedOffset = (amount * newBps) / 10000;
        uint256 expectedRecipient = amount - expectedOffset;

        vm.prank(guardian);
        angel.createAward(user, amount);
        vm.prank(verifier);
        angel.verifyAward(0);

        vm.deal(address(angel), amount);

        uint256 recipientBefore = user.balance;
        uint256 offsetBefore = offsetRecipient.balance;

        angel.distributeAward(0);

        assertEq(user.balance - recipientBefore, expectedRecipient);
        assertEq(offsetRecipient.balance - offsetBefore, expectedOffset);
    }
}

// Helper contract for filtering tests
contract DummyContract {}
