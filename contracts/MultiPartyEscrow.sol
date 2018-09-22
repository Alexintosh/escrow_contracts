pragma solidity ^0.4.24;

import "openzeppelin-solidity/contracts/token/ERC20/ERC20.sol";

contract MultiPartyEscrow {
    using SafeMath for uint256;
    

    //the full ID of the singular payment channel = "[this, channel_id, nonce]"
    struct PaymentChannel {
        address sender;      // The account sending payments.
        address receiver;    // The account receiving the payments.
        uint32  replica_id;  // id of particular service replica
        uint256 value;       // Total amount of tokens deposited to the channel. 
        uint32  nonce;       // "id" of the channel (after parly closed channel) 
        uint256 expiration;  // Timeout in case the recipient never closes.
    }


    mapping (uint256 => PaymentChannel) public channels;
    mapping (address => uint256)        public balances; //tokens which have been deposit but haven't been escrowed in the channels
    
    uint256 next_channel; //id of the next channel
 
    ERC20 public token; // Address of token contract


    constructor (address _token)
    public
    {
        token = ERC20(_token);
    }

    
    function deposit(uint256 value) 
    returns(bool)
    public 
    {
        require(token.transferFrom(msg.sender, this, value), "Unable to transfer token to the contract"));
        balances[msg.sender] += value;
        return true;
    }
    
    function withdraw(uint256 value)
    returns(bool)
    public
    {
        require(balances[msg.sender] >= value);
        require(token.transfer(msg.sender, value));
        balances[msg.sender] -= value;
        return true;
    }
    
    //open a channel, tokan should be already being deposit
    function open_channel(address  recipient, uint256 value, uint256 expiration, uint256 replica_id) 
    returns(bool)
    public 
    {
        require(balances[msg.sender] >= value)
        channels[next_channel++] = PaymentChannel({
            sender       : msg.sender,
            recipient    : recipient,
            value        : value,
            replica_id   : replica_id,
            nonce        : 0,
            expiration   : expiration,
        });
        balances[msg.sender] -= value;
        return true;
    }
    


    function deposit_and_open_channel(address  recipient, uint256 value, uint256 expiration, uint256 replica_id)
    public
    {
        require(deposit(value));
        require(open_channel(recipient, value, expiration, replica_id));
        return true;
    }

    //open a channel from the recipient side. Sender should send the signed permission to open the channel
    function open_channel_by_recipient(address  sender, uint256 value, uint256 expiration, uint256 replica_id, bytes memory signature) 
    returns(bool)
    public 
    {
        require(balances[sender] >= value)
        require(isValidSignature_open_channel(msg.sender, value, expiration, replica_id, signature, sender));
        channels[next_channel++] = PaymentChannel({
            sender       : sender,
            recipient    : msg.sender,
            value        : value,
            replica_id   : replica_id,
            nonce        : 0,
            expiration   : expiration,
        });
        balances[sender] -= value;
        return true;
    }
 
    function _channel_sendback_and_reopen(uint256 channel_id)
    private
    {
        PaymentChannel storage channel = channels[channel_id];
        balances[channel.sender]      += channel.value 
        channel.value                  = 0
        channel.nonce                 += 1
        channel.expiration             = 0
    }

    // the recipient can close the channel at any time by presenting a
    // signed amount from the sender. The recipient will be sent that amount. The recipient can choose: 
    // send the remainder to the sender (is_sendback == true), or put that amount into the new channel.
    function channel_claim(uint256 channel_id, uint256 amount, bytes memory signature, bool is_sendback) 
    public 
    {
        PaymentChannel storage channel = channels[channel_id];
        require(amount <= channel.value);
        require(msg.sender == channel.recipient);
 
        //"this" will be added later 
        require(isValidSignature_claim(channel_id, channel.nonce, amount, signature, channel.sender));
        
        balances[msg.sender] += amount;
        channels[channel_id] -= amount;
    
        if (is_sendback)    
            {
                _channel_refund_and_reopen(channel_id);
            }
            else
            {
                //simple reopen the new "channel"        
                channels[channel_id].nonce += 1;
            }
    }


    /// the sender can extend the expiration at any time
    function channel_extend(uint256 channel_id, uint256 new_expiration) 
    public 
    {
        PaymentChannel storage channel = channels[channel_id];

        require(msg.sender == channel.sender);
        require(new_expiration > channel.expiration);

        channels[channel_id] = new_expiration;
    }

    // sender can claim refund if the timeout is reached 
    function channel_claim_timeout(uint256 channel_id) 
    public 
    {
        require(msg.sender == channel[channel_id].sender)
        require(now >= channel[channel_id].expiration);
        _channel_refund_and_reopen();
    }


    function isValidSignature_open_channel(address recipent, uint256 value, uint256 expiration, uint256 replica_id bytes memory signature, address sender)
    internal
    view
	returns (bool)
    {
        bytes32 message = prefixed(keccak256(abi.encodePacked(this, recipent, value, expiration, replica_id)));
        // check that the signature is from the payment sender
        return recoverSigner(message, signature) == sender;
    }

    function isValidSignature_claim(uint256 channel_id, uint256 nonce, uint256 amount, bytes memory signature, address sender)
    internal
    view
	returns (bool)
    {
        bytes32 message = prefixed(keccak256(abi.encodePacked(this, channel_id, nonce, amount)));
        // check that the signature is from the payment sender
        return recoverSigner(message, signature) == sender;
    }


    function splitSignature(bytes memory sig)
    internal
    pure
    returns (uint8 v, bytes32 r, bytes32 s)
    {
        require(sig.length == 65);

        assembly {
            // first 32 bytes, after the length prefix
            r := mload(add(sig, 32))
            // second 32 bytes
            s := mload(add(sig, 64))
            // final byte
            v := and(mload(add(sig, 65)), 255)
        }
        
        if (v < 27) v += 27;

        return (v, r, s);
    }

    function recoverSigner(bytes32 message, bytes memory sig)
    internal
    pure
    returns (address)
    {
        (uint8 v, bytes32 r, bytes32 s) = splitSignature(sig);

        return ecrecover(message, v, r, s);
    }

    /// builds a prefixed hash to mimic the behavior of eth_sign.
    function prefixed(bytes32 hash) internal pure returns (bytes32) 
    {
        return keccak256(abi.encodePacked("\x19Ethereum Signed Message:\n32", hash));
    }
}