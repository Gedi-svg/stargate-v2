// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.22;

import { MessagingFee } from "@layerzerolabs/lz-evm-oapp-v2/contracts/oft/interfaces/IOFT.sol";

import { ICreditMessaging, TargetCreditBatch, TargetCredit } from "../interfaces/ICreditMessaging.sol";
import { ICreditMessagingHandler, Credit } from "../interfaces/ICreditMessagingHandler.sol";
import { CreditMsgCodec, CreditBatch } from "../libs/CreditMsgCodec.sol";
import { CreditMessagingOptions } from "./CreditMessagingOptions.sol";
import { MessagingBase, Origin } from "./MessagingBase.sol";
import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { ReadCodecV1, EVMCallRequestV1, EVMCallComputeV1 } from "@layerzerolabs/oapp-evm/contracts/oapp/libs/ReadCodecV1.sol";
contract CreditMessaging is MessagingBase, CreditMessagingOptions, ICreditMessaging {
    
    constructor(address _endpoint, address _owner) MessagingBase(_endpoint, _owner) Ownable(_owner) {}
    
    receive() external payable  {}
    fallback() external payable  {}
    
    function addressToBytes32(address _addr) internal pure returns (bytes32) {
        return bytes32(uint256(uint160(_addr)));
    }
    

    function withdraw(address payable _to, uint256 _amount) external onlyOwner {
        require(_amount <= address(this).balance, "Insufficient balance");
        (bool ok, ) = _to.call{value: _amount}("");
        require(ok, "Withdraw failed");
    }
    // ---------------------------------- Only Planner ------------------------------------------

    function sendCredits(uint32 _dstEid, TargetCreditBatch[] calldata _creditBatches) external payable virtual onlyPlanner {
        CreditBatch[] memory batches = new CreditBatch[](_creditBatches.length);
        uint256 index = 0;
        uint128 totalCreditNum = 0; // total number of credits in all batches

        for (uint256 i = 0; i < _creditBatches.length; i++) {
            TargetCreditBatch calldata targetBatch = _creditBatches[i];
            Credit[] memory actualCredits = ICreditMessagingHandler(_safeGetStargateImpl(targetBatch.assetId))
                .sendCredits(_dstEid, targetBatch.credits);
            if (actualCredits.length > 0) {
                batches[index++] = CreditBatch(targetBatch.assetId, actualCredits);
                totalCreditNum += uint128(actualCredits.length); // safe cast
            }
        }

        if (index != 0) {
            // resize the array to the actual number of batches
            assembly {
                mstore(batches, index)
            } 
            bytes memory message =  _getCmd(address(this), _dstEid, batches, totalCreditNum);
            bytes memory options = _buildOptions(_dstEid, totalCreditNum);
            _lzSend(_dstEid, message, options, MessagingFee(msg.value, 0), msg.sender);
        }
    }

    function quoteSendCredits(
        uint32 _dstEid,
        TargetCreditBatch[] calldata _creditBatches
    ) external view virtual returns (MessagingFee memory fee) {
        CreditBatch[] memory creditBatches = new CreditBatch[](_creditBatches.length);
        uint128 creditNum = 0; // used for message encoding
        for (uint256 i = 0; i < _creditBatches.length; i++) {
            TargetCredit[] calldata targetCredits = _creditBatches[i].credits;
            Credit[] memory credits = new Credit[](targetCredits.length);
            creditNum += uint128(targetCredits.length); // safe cast
            for (uint256 j = 0; j < targetCredits.length; j++) {
                credits[j] = Credit(targetCredits[j].srcEid, targetCredits[j].amount);
            }
            creditBatches[i] = CreditBatch(_creditBatches[i].assetId, credits);
        }
        bytes memory message =  _getCmd(address(this), _dstEid, creditBatches, creditNum);
        bytes memory options = _buildOptions(_dstEid, creditNum);
        fee = _quote(_dstEid, message, options, false);
    }

    
    function receiveCredits(
        uint32 _srcEid,
        TargetCreditBatch[] calldata _creditBatches
    ) external virtual onlyPlanner {
        // Convert TargetCreditBatch (external format) to Credit[] and forward to the
        // corresponding Stargate implementation. The previous implementation used
        // an uninitialized array which caused assetId==0 and reverted with
        // Messaging_Unavailable().
        for (uint256 i = 0; i < _creditBatches.length; i++) {
            TargetCreditBatch calldata tb = _creditBatches[i];
            TargetCredit[] calldata tcredits = tb.credits;
            Credit[] memory credits = new Credit[](tcredits.length);
            for (uint256 j = 0; j < tcredits.length; j++) {
                credits[j] = Credit(tcredits[j].srcEid, tcredits[j].amount);
            }
            ICreditMessagingHandler(_safeGetStargateImpl(tb.assetId)).receiveCredits(_srcEid, credits);
        }

    }
    function _getCmd(address _targetContractAddress, uint32 _targetEid, CreditBatch[] memory creditBatches, uint128 creditNum) internal view returns (bytes memory cmd) {
        // 1. Define WHAT function to call on the target contract
        //    Using the interface selector ensures type safety and correctness
        //    You can replace this with any public/external function or state variable
         
        bytes memory callData = abi.encodeWithSelector(CreditMsgCodec.encode.selector, creditBatches, creditNum);
        // 2. Build the read request specifying WHERE and HOW to fetch the data
        EVMCallRequestV1[] memory readRequests = new EVMCallRequestV1[](1);
        readRequests[0] = EVMCallRequestV1({
            appRequestLabel: 1, // Label for tracking this specific request
            targetEid: _targetEid, // WHICH chain to read from
            isBlockNum: false, // Use timestamp (not block number)
            blockNumOrTimestamp: uint64(block.timestamp), // WHEN to read the state (current time)
            confirmations: 15, // HOW many confirmations to wait for
            to: _targetContractAddress, // WHERE - the contract address to call
            callData: callData // WHAT - the function call to execute
        });
        EVMCallComputeV1 memory computeRequest = EVMCallComputeV1({
            computeSetting: 2,
            targetEid: _targetEid, // WHICH chain to read from
            isBlockNum: false, // Use timestamp (not block number);
            blockNumOrTimestamp: uint64(block.timestamp), // WHEN to read the state (current time)
            confirmations: 15, // HOW many confirmations to wait for
            to: _targetContractAddress // WHERE - the contract address to call
        });
       
            
        // 3. Encode the complete read command
        //    No compute logic needed for simple data reading
        //    The appLabel (0) can be used to identify different types of read operations
        cmd = ReadCodecV1.encode(0, readRequests, computeRequest);
    }
    // ---------------------------------- OApp Functions ------------------------------------------
    
    function _lzReceive(
        Origin calldata _origin,
        bytes32 /*_guid*/,
        bytes calldata _message,
        address /*_executor*/,
        bytes calldata /*_extraData*/
    ) internal override {
        CreditBatch[] memory creditBatches = CreditMsgCodec.decode(_message);
        uint256 batchNum = creditBatches.length;
        for (uint256 i = 0; i < batchNum; i++) {
            CreditBatch memory creditBatch = creditBatches[i];
            ICreditMessagingHandler(_safeGetStargateImpl(creditBatch.assetId)).receiveCredits(
                _origin.srcEid,
                creditBatch.credits
            );
        }
    }
}
