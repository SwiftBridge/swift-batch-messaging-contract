// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/Counters.sol";
import "@openzeppelin/contracts/utils/Strings.sol";

/**
 * @title BatchMessaging
 * @dev A contract for sending messages to multiple recipients in a single transaction
 * @author Swift v2 Team
 */
contract BatchMessaging is ReentrancyGuard, Ownable {
    using Counters for Counters.Counter;
    using Strings for uint256;

    // Events
    event BatchMessageSent(
        uint256 indexed batchId,
        address indexed sender,
        address[] recipients,
        string content,
        uint256 timestamp,
        uint256 gasUsed
    );

    event BatchMessageFailed(
        uint256 indexed batchId,
        address indexed sender,
        address[] failedRecipients,
        string reason
    );

    event RecipientAdded(
        uint256 indexed batchId,
        address indexed recipient
    );

    event RecipientRemoved(
        uint256 indexed batchId,
        address indexed recipient
    );

    // Structs
    struct BatchMessage {
        uint256 id;
        address sender;
        address[] recipients;
        string content;
        uint256 timestamp;
        string messageType;
        bool isCompleted;
        uint256 gasUsed;
        mapping(address => bool) deliveryStatus;
    }

    struct RecipientGroup {
        uint256 id;
        string name;
        address[] members;
        address creator;
        uint256 createdAt;
        bool isActive;
    }

    struct MessageTemplate {
        uint256 id;
        string name;
        string content;
        address creator;
        uint256 createdAt;
        bool isPublic;
    }

    // State variables
    Counters.Counter private _batchIdCounter;
    Counters.Counter private _groupIdCounter;
    Counters.Counter private _templateIdCounter;

    mapping(uint256 => BatchMessage) public batchMessages;
    mapping(uint256 => RecipientGroup) public recipientGroups;
    mapping(uint256 => MessageTemplate) public messageTemplates;
    mapping(address => uint256[]) public userBatches;
    mapping(address => uint256[]) public userGroups;
    mapping(address => uint256[]) public userTemplates;
    mapping(uint256 => mapping(address => bool)) public isGroupMember; // groupId => user => isMember

    // Constants
    uint256 public constant MAX_RECIPIENTS = 1000;
    uint256 public constant MAX_MESSAGE_LENGTH = 2000;
    uint256 public constant MAX_GROUP_SIZE = 500;
    uint256 public constant BATCH_FEE = 0.000003 ether; // ~$0.009 at $3000 ETH
    uint256 public constant GAS_LIMIT_PER_MESSAGE = 50000;

    // Modifiers
    modifier validRecipients(address[] memory _recipients) {
        require(_recipients.length > 0, "No recipients provided");
        require(_recipients.length <= MAX_RECIPIENTS, "Too many recipients");
        _;
    }

    modifier validMessageLength(string memory _content) {
        require(bytes(_content).length <= MAX_MESSAGE_LENGTH, "Message too long");
        require(bytes(_content).length > 0, "Message cannot be empty");
        _;
    }

    modifier batchExists(uint256 _batchId) {
        require(_batchId > 0 && _batchId <= _batchIdCounter.current(), "Batch does not exist");
        _;
    }

    modifier groupExists(uint256 _groupId) {
        require(_groupId > 0 && _groupId <= _groupIdCounter.current(), "Group does not exist");
        _;
    }

    modifier templateExists(uint256 _templateId) {
        require(_templateId > 0 && _templateId <= _templateIdCounter.current(), "Template does not exist");
        _;
    }

    modifier onlyGroupCreator(uint256 _groupId) {
        require(recipientGroups[_groupId].creator == msg.sender, "Only group creator can perform this action");
        _;
    }

    modifier onlyTemplateCreator(uint256 _templateId) {
        require(messageTemplates[_templateId].creator == msg.sender, "Only template creator can perform this action");
        _;
    }

    constructor() {
        _batchIdCounter.increment();
        _groupIdCounter.increment();
        _templateIdCounter.increment();
    }

    /**
     * @dev Send a batch message to multiple recipients
     * @param _recipients Array of recipient addresses
     * @param _content Message content
     * @param _messageType Type of message
     */
    function sendBatchMessage(
        address[] memory _recipients,
        string memory _content,
        string memory _messageType
    ) 
        external 
        payable 
        nonReentrant 
        validRecipients(_recipients)
        validMessageLength(_content)
    {
        require(msg.value >= BATCH_FEE, "Insufficient fee for batch message");
        
        uint256 batchId = _batchIdCounter.current();
        _batchIdCounter.increment();

        uint256 gasStart = gasleft();
        
        // Create batch message
        BatchMessage storage batch = batchMessages[batchId];
        batch.id = batchId;
        batch.sender = msg.sender;
        batch.content = _content;
        batch.timestamp = block.timestamp;
        batch.messageType = _messageType;
        batch.isCompleted = false;

        // Process recipients
        address[] memory filteredRecipients = new address[](_recipients.length);
        uint256 validCount = 0;

        for (uint256 i = 0; i < _recipients.length; i++) {
            address recipient = _recipients[i];
            if (recipient != address(0) && recipient != msg.sender) {
                filteredRecipients[validCount] = recipient;
                batch.recipients.push(recipient);
                batch.deliveryStatus[recipient] = false;
                validCount++;
            }
        }

        require(validCount > 0, "No valid recipients");

        // Emit events for each recipient
        for (uint256 i = 0; i < batch.recipients.length; i++) {
            emit RecipientAdded(batchId, batch.recipients[i]);
        }

        uint256 gasUsed = gasStart - gasleft();
        batch.gasUsed = gasUsed;
        batch.isCompleted = true;

        // Add to user's batches
        userBatches[msg.sender].push(batchId);

        emit BatchMessageSent(
            batchId,
            msg.sender,
            batch.recipients,
            _content,
            block.timestamp,
            gasUsed
        );
    }

    /**
     * @dev Send batch message to a group
     * @param _groupId ID of the recipient group
     * @param _content Message content
     * @param _messageType Type of message
     */
    function sendBatchMessageToGroup(
        uint256 _groupId,
        string memory _content,
        string memory _messageType
    ) 
        external 
        payable 
        nonReentrant 
        groupExists(_groupId)
        validMessageLength(_content)
    {
        require(msg.value >= BATCH_FEE, "Insufficient fee for batch message");
        
        RecipientGroup storage group = recipientGroups[_groupId];
        require(group.isActive, "Group is not active");
        require(group.creator == msg.sender || isGroupMember[_groupId][msg.sender], "Not a member of this group");

        uint256 batchId = _batchIdCounter.current();
        _batchIdCounter.increment();

        uint256 gasStart = gasleft();
        
        BatchMessage storage batch = batchMessages[batchId];
        batch.id = batchId;
        batch.sender = msg.sender;
        batch.content = _content;
        batch.timestamp = block.timestamp;
        batch.messageType = _messageType;
        batch.isCompleted = false;

        // Add group members as recipients
        for (uint256 i = 0; i < group.members.length; i++) {
            address member = group.members[i];
            if (member != msg.sender) {
                batch.recipients.push(member);
                batch.deliveryStatus[member] = false;
                emit RecipientAdded(batchId, member);
            }
        }

        require(batch.recipients.length > 0, "No valid recipients in group");

        uint256 gasUsed = gasStart - gasleft();
        batch.gasUsed = gasUsed;
        batch.isCompleted = true;

        userBatches[msg.sender].push(batchId);

        emit BatchMessageSent(
            batchId,
            msg.sender,
            batch.recipients,
            _content,
            block.timestamp,
            gasUsed
        );
    }

    /**
     * @dev Create a recipient group
     * @param _name Name of the group
     * @param _members Array of member addresses
     */
    function createRecipientGroup(
        string memory _name,
        address[] memory _members
    ) external {
        require(bytes(_name).length > 0, "Group name cannot be empty");
        require(_members.length <= MAX_GROUP_SIZE, "Group too large");

        uint256 groupId = _groupIdCounter.current();
        _groupIdCounter.increment();

        RecipientGroup storage group = recipientGroups[groupId];
        group.id = groupId;
        group.name = _name;
        group.creator = msg.sender;
        group.createdAt = block.timestamp;
        group.isActive = true;

        // Add members
        for (uint256 i = 0; i < _members.length; i++) {
            address member = _members[i];
            if (member != address(0) && !isGroupMember[groupId][member]) {
                group.members.push(member);
                isGroupMember[groupId][member] = true;
            }
        }

        userGroups[msg.sender].push(groupId);
    }

    /**
     * @dev Add member to group
     * @param _groupId ID of the group
     * @param _member Address of the member to add
     */
    function addGroupMember(uint256 _groupId, address _member)
        external
        groupExists(_groupId)
        onlyGroupCreator(_groupId)
    {
        require(_member != address(0), "Invalid member address");
        require(!isGroupMember[_groupId][_member], "Member already in group");

        RecipientGroup storage group = recipientGroups[_groupId];
        group.members.push(_member);
        isGroupMember[_groupId][_member] = true;
    }

    /**
     * @dev Remove member from group
     * @param _groupId ID of the group
     * @param _member Address of the member to remove
     */
    function removeGroupMember(uint256 _groupId, address _member)
        external
        groupExists(_groupId)
        onlyGroupCreator(_groupId)
    {
        RecipientGroup storage group = recipientGroups[_groupId];
        require(isGroupMember[_groupId][_member], "Member not in group");

        // Remove from mapping
        isGroupMember[_groupId][_member] = false;

        // Remove from array
        for (uint256 i = 0; i < group.members.length; i++) {
            if (group.members[i] == _member) {
                group.members[i] = group.members[group.members.length - 1];
                group.members.pop();
                break;
            }
        }
    }

    /**
     * @dev Create a message template
     * @param _name Name of the template
     * @param _content Template content
     * @param _isPublic Whether template is public
     */
    function createMessageTemplate(
        string memory _name,
        string memory _content,
        bool _isPublic
    ) external validMessageLength(_content) {
        require(bytes(_name).length > 0, "Template name cannot be empty");

        uint256 templateId = _templateIdCounter.current();
        _templateIdCounter.increment();

        MessageTemplate storage template = messageTemplates[templateId];
        template.id = templateId;
        template.name = _name;
        template.content = _content;
        template.creator = msg.sender;
        template.createdAt = block.timestamp;
        template.isPublic = _isPublic;

        userTemplates[msg.sender].push(templateId);
    }

    /**
     * @dev Send batch message using template
     * @param _templateId ID of the template
     * @param _recipients Array of recipient addresses
     * @param _messageType Type of message
     */
    function sendBatchMessageWithTemplate(
        uint256 _templateId,
        address[] memory _recipients,
        string memory _messageType
    ) 
        external 
        payable 
        nonReentrant 
        templateExists(_templateId)
        validRecipients(_recipients)
    {
        MessageTemplate storage template = messageTemplates[_templateId];
        require(template.isPublic || template.creator == msg.sender, "Template not accessible");

        require(msg.value >= BATCH_FEE, "Insufficient fee for batch message");

        uint256 batchId = _batchIdCounter.current();
        _batchIdCounter.increment();

        uint256 gasStart = gasleft();
        
        BatchMessage storage batch = batchMessages[batchId];
        batch.id = batchId;
        batch.sender = msg.sender;
        batch.content = template.content;
        batch.timestamp = block.timestamp;
        batch.messageType = _messageType;
        batch.isCompleted = false;

        // Process recipients
        for (uint256 i = 0; i < _recipients.length; i++) {
            address recipient = _recipients[i];
            if (recipient != address(0) && recipient != msg.sender) {
                batch.recipients.push(recipient);
                batch.deliveryStatus[recipient] = false;
                emit RecipientAdded(batchId, recipient);
            }
        }

        require(batch.recipients.length > 0, "No valid recipients");

        uint256 gasUsed = gasStart - gasleft();
        batch.gasUsed = gasUsed;
        batch.isCompleted = true;

        userBatches[msg.sender].push(batchId);

        emit BatchMessageSent(
            batchId,
            msg.sender,
            batch.recipients,
            template.content,
            block.timestamp,
            gasUsed
        );
    }

    /**
     * @dev Get batch message details
     * @param _batchId ID of the batch
     */
    function getBatchMessage(uint256 _batchId) 
        external 
        view 
        batchExists(_batchId)
        returns (
            uint256 id,
            address sender,
            address[] memory recipients,
            string memory content,
            uint256 timestamp,
            string memory messageType,
            bool isCompleted,
            uint256 gasUsed
        )
    {
        BatchMessage storage batch = batchMessages[_batchId];
        return (
            batch.id,
            batch.sender,
            batch.recipients,
            batch.content,
            batch.timestamp,
            batch.messageType,
            batch.isCompleted,
            batch.gasUsed
        );
    }

    /**
     * @dev Get recipient group details
     * @param _groupId ID of the group
     */
    function getRecipientGroup(uint256 _groupId) 
        external 
        view 
        groupExists(_groupId)
        returns (
            uint256 id,
            string memory name,
            address[] memory members,
            address creator,
            uint256 createdAt,
            bool isActive
        )
    {
        RecipientGroup storage group = recipientGroups[_groupId];
        return (
            group.id,
            group.name,
            group.members,
            group.creator,
            group.createdAt,
            group.isActive
        );
    }

    /**
     * @dev Get message template
     * @param _templateId ID of the template
     */
    function getMessageTemplate(uint256 _templateId) 
        external 
        view 
        templateExists(_templateId)
        returns (
            uint256 id,
            string memory name,
            string memory content,
            address creator,
            uint256 createdAt,
            bool isPublic
        )
    {
        MessageTemplate storage template = messageTemplates[_templateId];
        return (
            template.id,
            template.name,
            template.content,
            template.creator,
            template.createdAt,
            template.isPublic
        );
    }

    /**
     * @dev Get user's batch messages
     * @param _user Address of the user
     * @param _offset Starting index
     * @param _limit Number of batches to return
     * @return Array of batch IDs
     */
    function getUserBatches(
        address _user,
        uint256 _offset,
        uint256 _limit
    ) external view returns (uint256[] memory) {
        uint256[] memory userBatchIds = userBatches[_user];
        uint256 length = userBatchIds.length;
        
        if (_offset >= length) {
            return new uint256[](0);
        }

        uint256 end = _offset + _limit;
        if (end > length) {
            end = length;
        }

        uint256[] memory result = new uint256[](end - _offset);
        for (uint256 i = _offset; i < end; i++) {
            result[i - _offset] = userBatchIds[i];
        }

        return result;
    }

    /**
     * @dev Get user's groups
     * @param _user Address of the user
     * @return Array of group IDs
     */
    function getUserGroups(address _user) external view returns (uint256[] memory) {
        return userGroups[_user];
    }

    /**
     * @dev Get user's templates
     * @param _user Address of the user
     * @return Array of template IDs
     */
    function getUserTemplates(address _user) external view returns (uint256[] memory) {
        return userTemplates[_user];
    }

    /**
     * @dev Get total batch count
     * @return Total number of batches
     */
    function getTotalBatchCount() external view returns (uint256) {
        return _batchIdCounter.current() - 1;
    }

    /**
     * @dev Withdraw contract balance (only owner)
     */
    function withdraw() external onlyOwner nonReentrant {
        uint256 balance = address(this).balance;
        require(balance > 0, "No balance to withdraw");

        (bool success, ) = payable(owner()).call{value: balance}("");
        require(success, "Withdraw failed");
    }

    /**
     * @dev Update batch fee (only owner)
     * @notice This function is deprecated as BATCH_FEE is a constant
     * @param _newFee New fee amount (ignored - use for events only)
     */
    function updateBatchFee(uint256 _newFee) external view onlyOwner {
        require(_newFee > 0, "Fee must be greater than 0");
        // Note: BATCH_FEE is a constant and cannot be changed
        // This function is kept for interface compatibility only
    }
}
