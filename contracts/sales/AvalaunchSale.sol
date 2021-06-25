pragma solidity ^0.6.12;

import "../interfaces/IAdmin.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/cryptography/ECDSA.sol";
import "@openzeppelin/contracts/token/ERC20/SafeERC20.sol";



contract AvalaunchSale {

    using ECDSA for bytes32;
    using SafeMath for uint256;
    using SafeERC20 for IERC20;

    // Admin contract
    IAdmin public admin;

    // Token being sold
    IERC20 public token;

    struct Sale {
        // Address of sale owner
        address saleOwner;
        // Price of the token quoted in AVAX
        uint256 tokenPriceInAVAX;
        // Amount of tokens to sell
        uint256 amountOfTokensToSell;
        // Total tokens being sold
        uint256 totalTokensSold;
        // Total AVAX Raised
        uint256 totalAVAXRaised;
        // Registration time starts
        uint256 registrationTimeStarts;
        // Sale end time
        uint256 saleEnd;
        // When tokens can be withdrawn
        uint256 tokensUnlockTime;
    }

    // Participation structure
    struct Participation {
        uint256 amount;
        uint256 timestamp;
        uint256 roundId;
        bool isWithdrawn;
    }

    // Round structure
    struct Round {
        uint startTime;
        uint roundId;
        uint maxParticipation;
    }

    struct Registration {
        uint256 registrationTimeEnds;
        uint256 numberOfRegistrants;
    }

    // Sale
    Sale public sale;

    // Registration
    Registration registration;

    // Array storing IDS of rounds (IDs start from 1, so they can't be mapped as array indexes
    uint256 [] public roundIds;
    // Mapping round Id to round
    mapping (uint256 => Round) public roundIdToRound;
    // Mapping user to his participation
    mapping (address => Participation) public userToParticipation;
    // User to round for which he registered
    mapping (address => uint256) addressToRoundRegisteredFor;
    // mapping if user is participated or not
    mapping (address => bool) public isParticipated;
    // One ether in weis
    uint256 public constant one = 10**18;

    // Restricting calls only to sale owner
    modifier onlySaleOwner {
        require(msg.sender == sale.saleOwner, 'OnlySaleOwner:: Restricted');
        _;
    }

    modifier saleSet {
        // TODO: Iterate and make sure all the caps are set
        // TODO: Check that price is updated
        // TODO: Extend registration period, making sure it ends at least 24 hrs before 1st round start
        _;
    }

    event TokensSold(address user, uint256 amount);
    event UserRegistered(address user, uint256 roundId);
    event TokenPriceSet(uint256 newPrice);
    event MaxParticipationSet(uint256 roundId, uint256 maxParticipation);
    event TokensWithdrawn(address user, uint256 amount);


    constructor() public {
        // TODO: All the param validations are going to be here
    }

    /// @notice     Registration for sale.
    /// @param      signature is the message signed by the backend
    /// @param      roundId is the round for which user expressed interest to participate
    function registerForSale(
        bytes memory signature,
        uint roundId
    )
    public
    {
        require(roundId != 0, "Round ID can not be 0.");
        require(block.timestamp <= registration.registrationTimeEnds, "Registration gate is closed.");
        require(checkRegistrationSignature(signature, msg.sender, roundId), "Invalid signature");
        require(addressToRoundRegisteredFor[msg.sender] == 0, "User can not register twice.");

        // Rounds are 1,2,3
        addressToRoundRegisteredFor[msg.sender] = roundId;

        // Increment number of registered users
        registration.numberOfRegistrants++;

        // Emit Registration event
        emit UserRegistered(msg.sender, roundId);
    }


    /// @notice     Admin function, to update token price before sale to match the closest $ desired rate.
    function updateTokenPriceInAVAX(uint256 price)
    public
    {
        require(admin.isAdmin(msg.sender));
        require(block.timestamp < roundIdToRound[roundIds[0]].startTime, "1st round already started.");
        require(price > 0, "Price can not be 0.");

        // Set new price in AVAX
        sale.tokenPriceInAVAX = price;

        // Emit event token price is set
        emit TokenPriceSet(price);
    }


    /// @notice     Admin function to postpone the sale
    function postponeSale(uint timeToShift) external {
        require(admin.isAdmin(msg.sender));
        require(block.timestamp < roundIdToRound[roundIds[0]].startTime, "1st round already started.");

        // Iterate through all registered rounds and postpone them
        for(uint i = 0; i < roundIds.length; i++) {
            Round storage round = roundIdToRound[roundIds[i]];
            // Postpone sale
            round.startTime = round.startTime.add(timeToShift);
        }
    }

    /// @notice     Function to extend registration period
    function extendRegistrationPeriod(uint timeToAdd) external {
        require(admin.isAdmin(msg.sender), "Admin restricted function.");
        require(registration.registrationTimeEnds.add(timeToAdd) < roundIdToRound[roundIds[0]].startTime,
            "Registration period overflows sale start.");

        registration.registrationTimeEnds = registration.registrationTimeEnds.add(timeToAdd);
    }


    /// @notice     Admin function to set max participation cap per round
    function setCapPerRound(uint256[] calldata rounds, uint256[] calldata caps) public {
        require(admin.isAdmin(msg.sender));
        require(block.timestamp < roundIdToRound[rounds[0]].startTime, "1st round already started.");
        require(rounds.length == caps.length, "Arrays length is different.");

        for(uint i = 0; i < rounds.length; i++) {
            Round storage round = roundIdToRound[rounds[i]];
            round.maxParticipation = caps[i];

            emit MaxParticipationSet(rounds[i], round.maxParticipation);
        }
    }


    // Function for owner to deposit tokens, can be called only once.
    function depositTokens()
    public
    onlySaleOwner
    {
        require(sale.totalTokensSold == 0 && token.balanceOf(address(this)) == 0, "Deposit can be done only once");
        require(block.timestamp < roundIdToRound[roundIds[0]].startTime, "Deposit too late. Round already started.");

        token.safeTransferFrom(msg.sender, address(this), sale.amountOfTokensToSell);
    }


    // Function to participate in the sales
    function participate(
        bytes memory signature,
        uint256 amount,
        uint256 roundId
    )
    external
    payable
    {

        require(roundId != 0, "Round can not be 0.");

        require(amount <= roundIdToRound[roundId].maxParticipation, "Overflowing maximal participation for this round.");

        // Verify the signature
        require(checkSignature(signature, msg.sender, amount, roundId), "Invalid signature. Verification failed");

        // Check user haven't participated before
        require(isParticipated[msg.sender] == false, "User can participate only once.");

        // Disallow contract calls.
        require(msg.sender == tx.origin, "Only direct contract calls.");


        // Get current active round
        uint256 currentRound = getCurrentRound();

        // Assert that
        require(roundId == currentRound, "You can not participate in this round.");

        // Compute the amount of tokens user is buying
        uint256 amountOfTokensBuying = (msg.value).mul(one).div(sale.tokenPriceInAVAX);

        // Check in terms of user allo
        require(amountOfTokensBuying <= amount, "Trying to buy more than allowed.");

        // Increase amount of sold tokens
        sale.totalTokensSold = sale.totalTokensSold.add(amountOfTokensBuying);

        // Increase amount of AVAX raised
        sale.totalAVAXRaised = sale.totalAVAXRaised.add(msg.value);

        // Create participation object
        Participation memory p = Participation({
            amount: amountOfTokensBuying,
            timestamp: block.timestamp,
            roundId: roundId,
            isWithdrawn: false
        });

        // Add participation for user.
        userToParticipation[msg.sender] = p;

        // Mark user is participated
        isParticipated[msg.sender] = true;

        emit TokensSold(msg.sender, amountOfTokensBuying);
    }


    /// Users can claim their participation
    function withdrawTokens() public {
        require(block.timestamp >= sale.tokensUnlockTime, "Tokens can not be withdrawn yet.");

        Participation memory p = userToParticipation[msg.sender];

        if(!p.isWithdrawn) {
            p.isWithdrawn = true;
            token.safeTransfer(msg.sender, p.amount);
            // Emit event that tokens are withdrawn
            emit TokensWithdrawn(msg.sender, p.amount);
        } else {
            revert("Tokens already withdrawn.");
        }
    }


    // Internal function to handle safe transfer
    function safeTransferAVAX(
        address to,
        uint value
    )
    internal
    {
        (bool success,) = to.call{value:value}(new bytes(0));
        require(success, 'TransferHelper: AVAX_TRANSFER_FAILED');
    }


    /// Function to withdraw all the earnings and the leftover of the sale contract.
    function withdrawEarningsAndLeftover(
        bool withBurn
    )
    external
    onlySaleOwner
    {
        // Make sure sale ended
        require(block.timestamp >= sale.saleEnd);

        // Earnings amount of the owner in AVAX
        uint totalProfit = address(this).balance;

        // Amount of tokens which are not sold
        uint leftover = sale.amountOfTokensToSell.sub(sale.totalTokensSold);

        safeTransferAVAX(msg.sender, totalProfit);

        if(leftover > 0 && !withBurn) {
            token.safeTransfer(msg.sender, leftover);
            return;
        }

        if(withBurn) {
            token.safeTransfer(address(1), leftover);
        }
    }

    /// @notice     Get current round in progress.
    ///             If 0 is returned, means sale didn't start or it's ended.
    function getCurrentRound() public view returns (uint) {
        uint i = 0;
        if(block.timestamp < roundIdToRound[roundIds[0]].startTime) {
            return 0; // Sale didn't start yet.
        }
        while(block.timestamp < roundIdToRound[roundIds[i]].startTime && i < roundIds.length) {
            i++;
        }

        if(i == roundIds.length) {
            return 0; // Means sale is ended
        }

        return i;
    }

    /// @notice     Check signature user submits for registration.
    /// @param      signature is the message signed by the trusted entity (backend)
    /// @param      user is the address of user which is registering for sale
    /// @param      roundId is the round for which user is submitting registration
    function checkRegistrationSignature(bytes memory signature, address user, uint256 roundId) public view returns (bool) {
        bytes32 hash = keccak256(abi.encodePacked(user, roundId, address(this)));
        bytes32 messageHash = hash.toEthSignedMessageHash();
        return admin.isAdmin(messageHash.recover(signature));
    }


    // Function to check if admin was the message signer
    function checkSignature(bytes memory signature, address user, uint256 amount, uint256 round) public view returns (bool) {
        return admin.isAdmin(getParticipationSigner(signature, user, amount, round));
    }


    /// @notice     Check who signed the message
    /// @param      signature is the message allowing user to participate in sale
    /// @param      user is the address of user for which we're signing the message
    /// @param      amount is the maximal amount of tokens user can buy
    /// @param      roundId is the Id of the round user is participating.
    function getParticipationSigner(bytes memory signature, address user, uint256 amount, uint256 roundId) public pure returns (address) {
        bytes32 hash = keccak256(abi.encodePacked(user, amount, roundId));
        bytes32 messageHash = hash.toEthSignedMessageHash();
        return messageHash.recover(signature);
    }

    /// @notice     Function to get participation for passed user address
    function getParticipation(address _user) external view returns (uint256, uint256, uint256, bool) {
        Participation memory p = userToParticipation[_user];
        return (
            p.amount,
            p.timestamp,
            p.roundId,
            p.isWithdrawn
        );
    }

    /// @notice     Function to get info about the registration
    function getRegistrationInfo() external view returns (uint256, uint256) {
        return (
            registration.registrationTimeEnds,
            registration.numberOfRegistrants
        );
    }

}