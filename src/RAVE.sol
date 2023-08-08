// SPDX-License-Identifier: Apache-2.0
pragma solidity >=0.8.0 <0.9.0;

import { X509Verifier } from "./X509Verifier.sol";
import { JSONBuilder } from "./JSONBuilder.sol";
import { BytesUtils } from "ens-contracts/dnssec-oracle/BytesUtils.sol";
import { Base64 } from "openzeppelin-contracts/contracts/utils/Base64.sol";
import { RAVEBase } from "./RAVEBase.sol";
import { Test, console } from "forge-std/Test.sol";

/**
 * @title RAVE
 * @author PufferFinance
 * @custom:security-contact security@puffer.fi
 * @notice RAVe is a smart contract for verifying Remote Attestation evidence.
 */
contract RAVE is Test, RAVEBase, JSONBuilder, X509Verifier {
    using BytesUtils for *;

    constructor() { }

    /**
     * @inheritdoc RAVEBase
     */
    function verifyRemoteAttestation(
        // ABI encoded list of report fields as bytes.
        bytes calldata reportFieldsABI,
        bytes calldata sig,
        bytes memory signingMod,
        bytes memory signingExp,
        bytes32 mrenclave,
        bytes32 mrsigner
    ) public view override returns (bytes memory payload) {
        // Decode the encoded report JSON values to a Values struct and reconstruct the original JSON string
        (Values memory reportValues, bytes memory reportBytes) = _buildReportBytes(reportFieldsABI);
        console.logBytes(reportBytes);

        // Verify the report was signed by the SigningPK
        if (!verifyRSA(reportBytes, sig, signingMod, signingExp)) {
            revert BadReportSignature();
        }

        // Verify the report's contents match the expected
        payload = _verifyReportContents(reportValues, mrenclave, mrsigner);
        return payload;
    }

    /**
     * @inheritdoc RAVEBase
     */
    function rave(
        // ABI encoded list of report fields as bytes.
        // current incorrectly passing json.
        bytes calldata report,
        bytes calldata sig,
        bytes memory leafX509Cert,
        bytes memory signingMod,
        bytes memory signingExp,
        bytes32 mrenclave,
        bytes32 mrsigner
    ) public view override returns (bytes memory payload) {
        // Verify the leafX509Cert was signed with signingMod and signingExp
        (bytes memory leafCertModulus, bytes memory leafCertExponent) =
           verifySignedX509(leafX509Cert, signingMod, signingExp);

        // Verify report has expected fields then extract its payload
        payload = verifyRemoteAttestation(report, sig, leafCertModulus, leafCertExponent, mrenclave, mrsigner);
        return payload;
    }

    /*
    * @dev Builds the JSON report string from the abi-encoded `encodedReportValues`. The assumption is that `isvEnclaveQuoteBody` value was previously base64 decoded off-chain and needs to be base64 encoded to produce the message-to-be-signed.

    Ref: https://www.intel.com/content/dam/develop/public/us/en/documents/sgx-attestation-api-spec.pdf p24

    * @param encodedReportValues The values from the attestation evidence report JSON from IAS.
    * @return reportValues The JSON values as a Values struct for easier processing downstream
    * @return reportBytes The exact message-to-be-signed
    */
    function _buildReportBytes(bytes memory encodedReportValues)
        internal
        view
        returns (Values memory reportValues, bytes memory reportBytes)
    {
        // Decode the report JSON values
        (
            // string of numbers = 123213124
            bytes memory id,

            // string of data:time = 2023-02-15T01:24:57.989456
            bytes memory timestamp,

            // string of numbers = 4
            bytes memory version,

            /*
                (opt) b64 EPID B (64 bytes) & EPID K (64 bytes)
                components of EPID signature. 
            */
            bytes memory epidPseudonym,

            // (opt) string with advisory url
            bytes memory advisoryURL,

            // (opt) string with a python-like list = ['test']
            bytes memory advisoryIDs,

            // string for the status = OK
            bytes memory isvEnclaveQuoteStatus,

            /*
                raw bytes of the quote body
                normally this field in the verification report is
                base64 encoded but having to decode this on-chain =
                horrible waste of gas.
            */
            bytes memory isvEnclaveQuoteBody
        ) = abi.decode(encodedReportValues, (bytes, bytes, bytes, bytes, bytes, bytes, bytes, bytes));

        // Assumes the quote body was already decoded off-chain
        bytes memory encBody = bytes(Base64.encode(isvEnclaveQuoteBody));

        // Pack values to struct
        reportValues = JSONBuilder.Values(
            id, timestamp, version, epidPseudonym, advisoryURL, advisoryIDs, isvEnclaveQuoteStatus, encBody
        );

        // Reconstruct the JSON report that was signed
        reportBytes = bytes(buildJSON(reportValues));

        // Pass on the decoded value for later processing
        reportValues.isvEnclaveQuoteBody = isvEnclaveQuoteBody;
    }

    /*
    * @dev Parses a report, verifies the fields are correctly set, and extracts the enclave' 64 byte commitment.
    * @param reportValues The values from the attestation evidence report JSON from IAS.
    * @param mrenclave The expected enclave measurement.
    * @param mrsigner The expected enclave signer.
    * @return The 64 byte payload if the mrenclave and mrsigner values were correctly set.
    */
    function _verifyReportContents(Values memory reportValues, bytes32 mrenclave, bytes32 mrsigner)
        internal
        pure
        returns (bytes memory payload)
    {
        // check enclave status
        bytes32 status = keccak256(reportValues.isvEnclaveQuoteStatus);
        require(status == OK_STATUS || status == HARDENING_STATUS, "bad isvEnclaveQuoteStatus");

        // quote body is already base64 decoded
        bytes memory quoteBody = reportValues.isvEnclaveQuoteBody;
        assert(quoteBody.length == QUOTE_BODY_LENGTH);

        // Verify report's MRENCLAVE matches the expected
        bytes32 mre = quoteBody.readBytes32(MRENCLAVE_OFFSET);
        require(mre == mrenclave);

        // Verify report's MRSIGNER matches the expected
        bytes32 mrs = quoteBody.readBytes32(MRSIGNER_OFFSET);
        require(mrs == mrsigner);

        // Verify report's <= 64B payload matches the expected
        payload = quoteBody.substring(PAYLOAD_OFFSET, PAYLOAD_SIZE);
    }
}
