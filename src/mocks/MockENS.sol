// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import "src/interfaces/IENSRegistrarController.sol";
import "solady/tokens/ERC721.sol";
import "solady/utils/SafeTransferLib.sol";

contract MockENS is IETHRegistrarController, ERC721 {
    uint256 constant MIN_REGISTRATION_DURATION = 1 hours;
    uint256 constant PRICE = 100;
    uint256 constant MIN_COMMITMENT_AGE = 1 minutes;
    uint256 constant MAX_COMMITMENT_AGE = 1 days;

    address internal immutable TOKEN;

    mapping(bytes32 => uint256) public commitments;
    mapping(uint256 id => string) internal names;

    constructor(address token) {
        TOKEN = token;
    }
    function available(string memory label) external returns (bool) { }

    function commit(bytes32 commitment) external {
        require(commitments[commitment] == 0);
        commitments[commitment] = block.timestamp;
    }

    function makeCommitment(Registration calldata registration)
        public
        pure
        override
        returns (bytes32 commitment)
    {
        return keccak256(abi.encode(registration));
    }

    function register(Registration calldata registration) external payable {
        require(msg.value >= PRICE, "Insufficient payment");

        bytes32 labelhash = keccak256(bytes(registration.label));

        bytes32 commitment = makeCommitment(registration);
        uint256 commitmentTimestamp = commitments[commitment];

        require(commitmentTimestamp > 0, "Commitment not found");
        require(block.timestamp >= commitmentTimestamp + MIN_COMMITMENT_AGE, "Commitment too new");
        require(block.timestamp <= commitmentTimestamp + MAX_COMMITMENT_AGE, "Commitment too old");

        delete (commitments[commitment]);

        _mint(registration.owner, uint256(labelhash));
        names[uint256(labelhash)] = registration.label;
    }

    function registerWithERC20(Registration calldata registration) external {
        bytes32 labelhash = keccak256(bytes(registration.label));

        bytes32 commitment = makeCommitment(registration);
        uint256 commitmentTimestamp = commitments[commitment];

        require(commitmentTimestamp > 0, "Commitment not found");
        require(block.timestamp >= commitmentTimestamp + MIN_COMMITMENT_AGE, "Commitment too new");
        require(block.timestamp <= commitmentTimestamp + MAX_COMMITMENT_AGE, "Commitment too old");

        delete (commitments[commitment]);

        // Transfer PRICE amount of TOKEN from msg.sender to this contract
        SafeTransferLib.safeTransferFrom(TOKEN, msg.sender, address(this), PRICE);

        _mint(registration.owner, uint256(labelhash));
        names[uint256(labelhash)] = registration.label;
    }

    function renew(string calldata label, uint256 duration, bytes32 referrer) external payable { }

    function name() public view virtual override returns (string memory) { }
    function symbol() public view virtual override returns (string memory) { }

    function tokenURI(uint256 id) public view virtual override returns (string memory) {
        return names[id];
    }
}
