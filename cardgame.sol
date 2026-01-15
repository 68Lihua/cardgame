// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

contract CardGame {
    enum Result { Pending, Win, Lose, Draw, Abandoned }

    struct Card {
        uint8 rank; // 0-12 对应 A-K
        uint8 suit; // 0-3 对应 红桃, 黑桃, 方块, 梅花
        bool isDrawn;
    }

    struct GameSession {
        Card[] playerCards;
        Card[] aiCards;
        uint256 betAmount;
        bool isActive;
        bool settled;
    }

    mapping(address => GameSession) public sessions;
    mapping(address => uint256) public aiWinStreak; // 记录AI对某个玩家的连胜次数

    event GameStarted(address indexed player, uint256 bet);
    event CardDrawn(address indexed player, uint8 rank, uint8 suit);
    event GameSettled(address indexed player, string result, uint256 reward);

    receive() external payable {} // 允许合约接收注资

    // 内部方法：生成伪随机牌
    function _drawCard(address _player, uint256 _salt) internal view returns (Card memory) {
        uint256 seed = uint256(keccak256(abi.encodePacked(block.timestamp, block.prevrandao, _player, _salt)));
        return Card({
            rank: uint8(seed % 13),
            suit: uint8((seed / 13) % 4),
            isDrawn: true
        });
    }

    // 开始游戏
    function startGame() external payable {
        require(msg.value >= 0.1 ether && msg.value <= 2 ether, "Bet must be between 0.1 and 2 ETH");
        require(!sessions[msg.sender].isActive, "Game already in progress");

        GameSession storage session = sessions[msg.sender];
        delete session.playerCards;
        delete session.aiCards;

        session.betAmount = msg.value;
        session.isActive = true;
        session.settled = false;

        // 初始发牌：玩家1张，AI 1张
        session.playerCards.push(_drawCard(msg.sender, 1));
        // AI 策略：如果AI连胜3局以上，增加AI抽到小牌的概率（示弱机制）
        Card memory aiExtraCard = _drawCard(msg.sender, 2);
        if (aiWinStreak[msg.sender] >= 3 && aiExtraCard.rank > 5) {
            aiExtraCard.rank = uint8(aiExtraCard.rank % 6); // 强制变小
        }
        session.aiCards.push(aiExtraCard);

        emit GameStarted(msg.sender, msg.value);
    }

    // 加牌 (Hit)
    function hitCard() external {
        GameSession storage session = sessions[msg.sender];
        require(session.isActive, "No active game");
        require(session.playerCards.length < 3, "Max 2 additional cards");

        session.playerCards.push(_drawCard(msg.sender, session.playerCards.length + 10));
        session.aiCards.push(_drawCard(msg.sender, session.aiCards.length+20));
    }

    // 开牌判胜负 (Judge)
    function judgeResult() external returns (string memory result, Card[] memory aiCards) {
        GameSession storage session = sessions[msg.sender];
        require(session.isActive, "No active game");

        uint256 playerTotal = _calculateTotal(session.playerCards);

        uint256 aiTotal = _calculateTotal(session.aiCards);

        string memory resultStr;
        if (playerTotal > aiTotal) {
            resultStr = "win";
            uint256 payout = session.betAmount * 2;
            require(address(this).balance >= payout, "Contract insufficient funds");
            payable(msg.sender).transfer(payout);
            aiWinStreak[msg.sender] = 0;
        } else if (playerTotal < aiTotal) {
            resultStr = "lose";
            aiWinStreak[msg.sender]++;
        } else {
            resultStr = "draw";
            payable(msg.sender).transfer(session.betAmount); // 平局退回
        }

        session.isActive = false;
        session.settled = true;
        
        emit GameSettled(msg.sender, resultStr, (playerTotal > aiTotal ? session.betAmount * 2 : 0));
        return (resultStr, session.aiCards);
    }

    // 弃牌 (Abandon)
    function abandon() external returns (bool isLose, Card[] memory aiCards) {
        GameSession storage session = sessions[msg.sender];
        require(session.isActive, "No active game");

        uint256 refund = session.betAmount / 2;
        payable(msg.sender).transfer(refund);

        aiWinStreak[msg.sender]++;
        session.isActive = false;
        session.settled = true;

        return (true, session.aiCards);
    }

    // 重置游戏
    function resetGame() external {
        GameSession storage session = sessions[msg.sender];
        session.isActive = false;
        delete session.playerCards;
        delete session.aiCards;
    }

    // 工具方法：计算总点数
    function _calculateTotal(Card[] memory _cards) internal pure returns (uint256) {
        uint256 total = 0;
        for (uint i = 0; i < _cards.length; i++) {
            total += (uint256(_cards[i].rank) + 1);
        }
        return total;
    }

    // 查看玩家手牌
    function getPlayerCards() external view returns (Card[] memory) {
        return sessions[msg.sender].playerCards;
    }

    // 在合约中添加此函数，方便前端在游戏结束后查看 AI 抽到了什么
    function getAiCards(address _player) external view returns (Card[] memory) {
        return sessions[_player].aiCards;
    }

    // 查看合约余额
    function getContractBalance() external view returns (uint256) {
        return address(this).balance;
    }

    // 合约所有者（部署者）
    address private immutable _owner;

    // 构造函数
    constructor() {
        _owner = msg.sender; // 部署合约的地址为所有者
    }

    // 仅所有者可调用的修饰符
    modifier onlyOwner() {
        require(msg.sender == _owner, "Only owner can call this function");
        _;
    }

    // 提取全部余额
    function withdrawAll() external onlyOwner {
        uint256 balance = address(this).balance;
        require(balance > 0, "Contract balance is zero");
        
        // 转账到所有者地址
        (bool success, ) = _owner.call{value: balance}("");
        require(success, "Withdraw failed");
    }

    // 提取指定金额
    function withdrawAmount(uint256 amount) external onlyOwner {
        require(amount > 0 && amount <= address(this).balance, "Invalid amount");
        
        (bool success, ) = _owner.call{value: amount}("");
        require(success, "Withdraw failed");
    }
}