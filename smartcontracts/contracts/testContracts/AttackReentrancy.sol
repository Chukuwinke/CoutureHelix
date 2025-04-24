// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/*
  This contract attempts a reentrant call on the forwarder's
  executeWithPermitAndReimbursement function.
*/
interface ICustomForwarder {
    struct ForwardRequestData {
        address from;
        address to;
        uint256 value;
        uint256 gas;
        uint256 nonce;
        bytes data;
    }
    function executeWithPermitAndReimbursement(
        ForwardRequestData calldata request,
        uint256 gasUsed,
        uint256 gasPriceInMatic,
        uint256 tokenToMaticRate,
        uint256 permitDeadline,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external payable;
}

contract AttackReentrancy {
    ICustomForwarder public forwarder;
    bool public reentered;

    constructor(address _forwarder) {
        forwarder = ICustomForwarder(_forwarder);
        reentered = false;
    }

    // Fallback function attempts reentrant call.
    fallback() external payable {
        if (!reentered) {
            reentered = true;
            // Prepare dummy parameters for reentrant call.
            ICustomForwarder.ForwardRequestData memory dummyRequest = ICustomForwarder.ForwardRequestData({
                from: address(this),
                to: address(0), // dummy
                value: 0,
                gas: 50000,
                nonce: 0,
                data: "0x"
            });
            // This second call (triggered in fallback) should revert due to nonReentrancy.
            forwarder.executeWithPermitAndReimbursement(
                dummyRequest,
                21000,
                10,
                1,
                block.timestamp + 1000,
                27,
                bytes32(0),
                bytes32(0)
            );
        }
    }

    // Initiate attack: The initial call should trigger the fallback reentrant call.
    function attack() external payable {
        ICustomForwarder.ForwardRequestData memory dummyRequest = ICustomForwarder.ForwardRequestData({
            from: address(this),
            to: address(0), // dummy target for testing
            value: 0,
            gas: 50000,
            nonce: 0,
            data: "0x"
        });
        forwarder.executeWithPermitAndReimbursement(
            dummyRequest,
            21000,
            10,
            1,
            block.timestamp + 1000,
            27,
            bytes32(0),
            bytes32(0)
        );
    }
}
