// SPDX-License-Identifier: MIT
pragma solidity 0.8.7;

import {NFTSeaToken} from "../NFTSeaToken.sol";
import {TokenDistributor} from "../TokenDistributor.sol";
import {FeeSharingSystem} from "../FeeSharingSystem.sol";
import {FeeSharingSetter} from "../FeeSharingSetter.sol";

import {AggregatorFeeSharingWithUniswapV3} from "../AggregatorFeeSharingWithUniswapV3.sol";
import {MockERC20} from "./utils/MockERC20.sol";
import {MockUniswapV3Router} from "./utils/MockUniswapV3Router.sol";

import {TestHelpers} from "./TestHelpers.sol";

abstract contract TestParameters {
    address internal _PREMINT_RECEIVER = address(42);
    address internal _TOKEN_SPLITTER = address(88);
    uint256 internal _CAP = 25000;
    uint256 internal _PREMINT_AMOUNT = 6250;
    uint256 internal _START_BLOCK;
}

contract AggregatorTest is TestParameters, TestHelpers {
    NFTSeaToken public NFTSeaToken;
    TokenDistributor public tokenDistributor;
    FeeSharingSystem public feeSharingSystem;
    FeeSharingSetter public feeSharingSetter;
    AggregatorFeeSharingWithUniswapV3 public aggregatorFeeSharingWithUniswapV3;
    MockUniswapV3Router public uniswapRouter;
    MockERC20 public rewardToken;

    function setUp() public {
        // 0. Mock WETH deployment
        rewardToken = new MockERC20("WETH", "Wrapped Ether");

        // 1. Mock UniswapV3Router deployment
        uniswapRouter = new MockUniswapV3Router();

        // 2. NFTSeaToken deployment
        NFTSeaToken = new NFTSeaToken(_PREMINT_RECEIVER, _parseEther(_PREMINT_AMOUNT), _parseEther(_CAP));

        // 3. TokenDistributor deployment
        uint256[] memory rewardsPerBlockForStaking = new uint256[](4);
        rewardsPerBlockForStaking[0] = _parseEther(30);
        rewardsPerBlockForStaking[1] = _parseEther(15);
        rewardsPerBlockForStaking[2] = _parseEtherWithFloating(75, 1); // 7.5
        rewardsPerBlockForStaking[3] = _parseEtherWithFloating(375, 2); // 3.75

        uint256[] memory rewardsPerBlockForOthers = new uint256[](4);
        rewardsPerBlockForOthers[0] = _parseEther(70);
        rewardsPerBlockForOthers[1] = _parseEther(35);
        rewardsPerBlockForOthers[2] = _parseEtherWithFloating(175, 1); // 17.5
        rewardsPerBlockForOthers[3] = _parseEtherWithFloating(875, 2); // 8.75

        uint256[] memory periodLengthesInBlocks = new uint256[](4);
        periodLengthesInBlocks[0] = uint256(100);
        periodLengthesInBlocks[1] = uint256(100);
        periodLengthesInBlocks[2] = uint256(100);
        periodLengthesInBlocks[3] = uint256(100);

        _START_BLOCK = block.number + 10;

        // 4. TokenDistributor deployment
        tokenDistributor = new TokenDistributor(
            address(NFTSeaToken),
            _TOKEN_SPLITTER,
            _START_BLOCK,
            rewardsPerBlockForStaking,
            rewardsPerBlockForOthers,
            periodLengthesInBlocks,
            4
        );

        NFTSeaToken.transferOwnership(address(tokenDistributor));

        // 5. FeeSharingSystem deployment
        feeSharingSystem = new FeeSharingSystem(
            address(NFTSeaToken),
            address(rewardToken),
            address(tokenDistributor)
        );

        // 6. FeeSharingSetter deployment (w/ distribution period is set at 100 blocks)
        feeSharingSetter = new FeeSharingSetter(address(feeSharingSystem), 30, 1000, 100);
        feeSharingSetter.grantRole(feeSharingSetter.OPERATOR_ROLE(), feeSharingSystem.owner());
        feeSharingSystem.transferOwnership(address(feeSharingSetter));

        // 7. Aggregator deployment
        aggregatorFeeSharingWithUniswapV3 = new AggregatorFeeSharingWithUniswapV3(
            address(feeSharingSystem),
            address(uniswapRouter)
        );

        // 8. Distribute NFTS (from the premint) to user accounts
        address[4] memory users = [user1, user2, user3, user4];

        for (uint256 i = 0; i < users.length; i++) {
            cheats.prank(_PREMINT_RECEIVER);
            NFTSeaToken.transfer(users[i], _parseEther(300));

            cheats.prank(users[i]);
            NFTSeaToken.approve(address(aggregatorFeeSharingWithUniswapV3), type(uint256).max);
        }
    }

    function testConstructor() public {
        assertEq(NFTSeaToken.name(), "NFTSea Token");
        assertEq(NFTSeaToken.symbol(), "NFTS");
        assertEq(NFTSeaToken.totalSupply(), _parseEther(_PREMINT_AMOUNT));
        assertEq(_parseEther(1), _parseEtherWithFloating(1, 0));
    }

    function testDeposit() public asPrankedUser(user1) {
        aggregatorFeeSharingWithUniswapV3.deposit(_parseEther(100));

        uint256 currentBalanceUser1 = NFTSeaToken.balanceOf(user1);
        assertEq(aggregatorFeeSharingWithUniswapV3.userInfo(user1), _parseEther(100));
        assertEq(aggregatorFeeSharingWithUniswapV3.calculateSharesValueInNFTS(user1), _parseEther(100));
        assertEq(aggregatorFeeSharingWithUniswapV3.calculateSharePriceInPrimeShare(), 1e18);

        // Time travel by 1 block
        cheats.roll(_START_BLOCK + 1);
        assertEq(aggregatorFeeSharingWithUniswapV3.calculateSharesValueInNFTS(user1), _parseEther(130));
        assertEq(aggregatorFeeSharingWithUniswapV3.calculateSharePriceInNFTS(), _parseEtherWithFloating(13, 1));
        aggregatorFeeSharingWithUniswapV3.withdrawAll();

        // 200 NFTS + 130 NFTS = 330 NFTS
        assertEq(NFTSeaToken.balanceOf(user1), _parseEther(130) + currentBalanceUser1);
        assertEq(aggregatorFeeSharingWithUniswapV3.calculateSharesValueInNFTS(user1), _parseEther(0));

        aggregatorFeeSharingWithUniswapV3.deposit(_parseEther(100));
        aggregatorFeeSharingWithUniswapV3.deposit(_parseEther(100));

        cheats.roll(_START_BLOCK + 50);
        assertEq(aggregatorFeeSharingWithUniswapV3.userInfo(user1), _parseEther(200));
        assertEq(aggregatorFeeSharingWithUniswapV3.calculateSharesValueInNFTS(user1), _parseEther(200 + 49 * 30));
    }

    function testSameBlockDepositAndWithdraw(uint8 x, uint16 numberBlocks) public asPrankedUser(user1) {
        uint256 amountDeposit = _parseEther(x);
        cheats.assume(amountDeposit >= aggregatorFeeSharingWithUniswapV3.MINIMUM_DEPOSIT_NFTS());
        cheats.roll(_START_BLOCK + uint256(numberBlocks));

        aggregatorFeeSharingWithUniswapV3.deposit(amountDeposit);
        uint256 currentBalanceUser1 = NFTSeaToken.balanceOf(user1);
        aggregatorFeeSharingWithUniswapV3.withdrawAll();
        assertEq(NFTSeaToken.balanceOf(user1), currentBalanceUser1 + amountDeposit);
    }

    function testSameBlockMultipleDeposits(uint8 x, uint16 numberBlocks) public {
        uint256 amountDeposit = _parseEther(x);
        cheats.assume(amountDeposit >= aggregatorFeeSharingWithUniswapV3.MINIMUM_DEPOSIT_NFTS());
        cheats.roll(_START_BLOCK + uint256(numberBlocks));

        cheats.prank(user1);
        aggregatorFeeSharingWithUniswapV3.deposit(amountDeposit);

        cheats.prank(user2);
        aggregatorFeeSharingWithUniswapV3.deposit(amountDeposit);
        assertEq(aggregatorFeeSharingWithUniswapV3.userInfo(user1), aggregatorFeeSharingWithUniswapV3.userInfo(user2));
    }

    function testScenarioWithoutRouter() public {
        uint256 amountDeposit = _parseEther(100);
        cheats.roll(_START_BLOCK + 5);

        /** 1. Initial deposits at startBlock + 5
         */
        address[4] memory users = [user1, user2, user3, user4];
        for (uint256 i = 0; i < users.length; i++) {
            cheats.prank(users[i]);
            aggregatorFeeSharingWithUniswapV3.deposit(amountDeposit);
        }
        assertEq(aggregatorFeeSharingWithUniswapV3.userInfo(user1), aggregatorFeeSharingWithUniswapV3.userInfo(user2));

        /** 2. Time travel to startBlock + 20 (15 blocks later)
         * User1 withdraws funds
         */
        cheats.roll(_START_BLOCK + 20);

        uint256 currentBalanceUser = NFTSeaToken.balanceOf(user1);
        cheats.prank(user1);
        aggregatorFeeSharingWithUniswapV3.withdrawAll();

        // 15 blocks at 30 NFTS/block = 450 NFTS
        // 450 / 4 = 112.5 NFTS for user
        assertEq(
            NFTSeaToken.balanceOf(user1),
            currentBalanceUser + _parseEtherWithFloating(1125, 1) + amountDeposit
        );

        /** 3. Time travel to startBlock + 100 (80 blocks later)
         * User2 checks the value of her shares
         */
        cheats.roll(_START_BLOCK + 100);

        // 80 blocks at 30 NFTS/blocks = 2400 NFTS
        // 800 NFTS for user
        // Total value of the shares = 800 NFTS + 112.5 NFTS + 100 NFTS = 1012.5 NFTS
        // @dev To deal with minor precision losses due to division, we look at the boundaries
        assertQuasiEq(
            aggregatorFeeSharingWithUniswapV3.calculateSharesValueInNFTS(user2),
            _parseEtherWithFloating(10125, 1)
        );

        /** 4. Time travel to startBlock + 170 (70 blocks later)
         * User2 withdraws all
         */
        cheats.roll(_START_BLOCK + 170);
        currentBalanceUser = NFTSeaToken.balanceOf(user2);
        cheats.prank(user2);
        aggregatorFeeSharingWithUniswapV3.withdrawAll();

        // Previous value of shares of user2 = 1012.5 NFTS (see above)
        // 70 blocks at 15 NFTS/block = 1050 NFTS
        // 1050 NFTS / 3 = 350 NFTS for user
        // Total = 1362.5 NFTS
        assertQuasiEq(NFTSeaToken.balanceOf(user2), currentBalanceUser + _parseEtherWithFloating(13625, 1));

        /** 5. Time travel to startBlock + 400 (230 blocks later)
         * User3 withdraws all
         */
        cheats.roll(_START_BLOCK + 400);
        currentBalanceUser = NFTSeaToken.balanceOf(user3);
        cheats.prank(user3);
        aggregatorFeeSharingWithUniswapV3.withdrawAll();

        // Previous value of shares of user2 = 1362.5 NFTS (see above)
        // 30 blocks at 15 NFTS/block = 450 NFTS
        // 100 blocks at 7.5 NFTS/block = 750 NFTS
        // 100 blocks at 3.75 NFTS/block = 375 NFTS
        // 1575 NFTS / 2 = 787.5 NFTS
        // Total = 2150 NFTS
        assertQuasiEq(NFTSeaToken.balanceOf(user3), currentBalanceUser + _parseEther(2150));

        /** 6. Time travel to startBlock + 400 (230 blocks later)
         * User4 withdraws all
         */
        cheats.roll(_START_BLOCK + 450);
        currentBalanceUser = NFTSeaToken.balanceOf(user4);
        cheats.prank(user4);
        aggregatorFeeSharingWithUniswapV3.withdrawAll();

        // Should be same as user3 since NFTS distribution is stopped
        assertQuasiEq(NFTSeaToken.balanceOf(user4), currentBalanceUser + _parseEther(2150));

        // Verify the final total supply is equal to the cap - supply not minted (for first 5 blocks)
        assertEq(NFTSeaToken.totalSupply(), _parseEther(_CAP) - _parseEther(500));
    }

    function testScenarioWithRouter() public {
        /** 0. Initial set up
         */
        cheats.roll(_START_BLOCK);

        // Add 1000 WETH for distribution for next 100 blocks (10 WETH per block)
        rewardToken.mint(address(feeSharingSetter), _parseEther(1000));
        feeSharingSetter.updateRewards();
        feeSharingSetter.setNewRewardDurationInBlocks(300); // This will be adjusted for the second period
        assertEq(feeSharingSystem.currentRewardPerBlock(), _parseEther(10));

        aggregatorFeeSharingWithUniswapV3.startHarvest();
        aggregatorFeeSharingWithUniswapV3.updateThresholdAmount(_parseEtherWithFloating(5, 1)); // 1 WETH
        aggregatorFeeSharingWithUniswapV3.updateHarvestBufferBlocks(20);
        uniswapRouter.setMultiplier(15000); // 1 WETH = 1.5 NFTS
        aggregatorFeeSharingWithUniswapV3.updateMaxPriceOfNFTSInWETH(_parseEtherWithFloating(667, 3)); // 1 NFTS = 0.667 WETH

        // Transfer 4000 NFTS to mock router
        cheats.prank(_PREMINT_RECEIVER);
        NFTSeaToken.transfer(address(uniswapRouter), _parseEther(4000));

        uint256 amountDeposit = _parseEther(100);
        cheats.roll(_START_BLOCK + 5);

        /** 1. Initial deposits at startBlock + 5
         */
        address[4] memory users = [user1, user2, user3, user4];
        for (uint256 i = 0; i < users.length; i++) {
            cheats.prank(users[i]);
            aggregatorFeeSharingWithUniswapV3.deposit(amountDeposit);
        }

        /** 2. Time travel to startBlock + 20 (15 blocks later)
         * User1 withdraws funds
         */
        cheats.roll(_START_BLOCK + 20);

        uint256 currentBalanceUser = NFTSeaToken.balanceOf(user1);
        cheats.prank(user1);
        aggregatorFeeSharingWithUniswapV3.withdrawAll();

        // 15 blocks at 30 NFTS/block = 450 NFTS
        // + 150 WETH sold at 1 WETH = 1.5 NFTS --> 225 NFTS
        // 675 / 4 = 168.75 NFTS for user
        // @dev 50 WETH are lost to the fee sharing system contract since no user was staking for the first 5 blocks
        assertEq(
            NFTSeaToken.balanceOf(user1),
            currentBalanceUser + _parseEtherWithFloating(16875, 2) + amountDeposit
        );

        // 400 prime shares --> (450 + 225 + 4 * 100) = 1075
        // 1 prime share is worth 1075 / 400 = 2.6875
        assertEq(aggregatorFeeSharingWithUniswapV3.calculateSharePriceInNFTS(), _parseEtherWithFloating(26875, 4));

        // 400 shares --> (450 + 4 * 100) = 850
        // 1 share is worth 850 / 400 = 2.125
        assertEq(feeSharingSystem.calculateSharePriceInNFTS(), _parseEtherWithFloating(2125, 3));

        // 1 prime share is worth ~ 1.264 shares
        assertEq(
            aggregatorFeeSharingWithUniswapV3.calculateSharePriceInPrimeShare(),
            (aggregatorFeeSharingWithUniswapV3.calculateSharePriceInNFTS() * 1e18) /
                feeSharingSystem.calculateSharePriceInNFTS()
        );

        // User1 decides to re-deposit the exact same amount as the one earned
        cheats.prank(user1);
        aggregatorFeeSharingWithUniswapV3.deposit(_parseEtherWithFloating(16875, 2) + amountDeposit);

        assertEq(
            aggregatorFeeSharingWithUniswapV3.calculateSharesValueInNFTS(user1),
            aggregatorFeeSharingWithUniswapV3.calculateSharesValueInNFTS(user2)
        );

        /** 3. Time travel to startBlock + 100 (80 blocks later)
         * User1 withdraws
         */
        cheats.roll(_START_BLOCK + 100);
        assertEq(feeSharingSystem.periodEndBlock(), _START_BLOCK + 100);

        currentBalanceUser = NFTSeaToken.balanceOf(user1);
        cheats.prank(user1);
        aggregatorFeeSharingWithUniswapV3.withdrawAll();

        // Previous value of shares of user1 = 168.75 NFTS (see above)
        // 80 blocks at 30 NFTS/block = 2400 NFTS
        // + 800 WETH sold at 1 WETH = 1.5 NFTS --> 1200 NFTS
        // 3600 / 4 = 900 NFTS for user
        assertQuasiEq(
            NFTSeaToken.balanceOf(user1),
            currentBalanceUser + _parseEtherWithFloating(106875, 2) + amountDeposit
        );

        assertEq(feeSharingSystem.lastRewardBlock(), _START_BLOCK + 100);

        /** 4. Start of new reward period over 300 blocks
         */

        // Add 1500 WETH for distribution for next 300 blocks (5 WETH per block)
        cheats.roll(_START_BLOCK + 101);
        rewardToken.mint(address(feeSharingSetter), _parseEther(1500));
        feeSharingSetter.updateRewards();
        assertEq(feeSharingSystem.currentRewardPerBlock(), _parseEther(5));

        /** 5. Time travel to the end of the NFTS staking/fee-sharing period
         * All 3 users withdraw their funds
         */
        cheats.roll(_START_BLOCK + 401);

        // @dev currentBalanceUser is same for user2/user3/user4
        currentBalanceUser = NFTSeaToken.balanceOf(user2);

        for (uint256 i = 1; i < users.length; i++) {
            cheats.prank(users[i]);
            aggregatorFeeSharingWithUniswapV3.withdrawAll();
        }


        assertQuasiEq(
            NFTSeaToken.balanceOf(user2),
            _parseEther(1625) + _parseEtherWithFloating(106875, 2) + amountDeposit + currentBalanceUser
        );
        assertQuasiEq(NFTSeaToken.balanceOf(user2), NFTSeaToken.balanceOf(user3));
        assertQuasiEq(NFTSeaToken.balanceOf(user3), NFTSeaToken.balanceOf(user4));

        // There should be around 50 WETH left in the fee sharing contract (for the first 5 blocks without user staking)
        assertQuasiEq(rewardToken.balanceOf(address(feeSharingSystem)), _parseEther(50));

        // Verify the final total supply is equal to the cap - supply not minted (for first 5 blocks)
        assertEq(NFTSeaToken.totalSupply(), _parseEther(_CAP) - _parseEther(500));
    }
}
