// SPDX-License-Identifier: GPL-3.0-only

pragma solidity =0.7.6;
pragma abicoder v2;

// interface
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/SafeERC20.sol";
import {IEulerExec, IDToken} from "../interfaces/IEuler.sol";
import {WETH9} from "../external/WETH9.sol";

import {Address} from "@openzeppelin/contracts/utils/Address.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

// contract
import {CrabStrategyV2} from "./CrabStrategyV2.sol";
import {CrabStrategy} from "./CrabStrategy.sol";
import {StrategyMath} from "./base/StrategyMath.sol";

/**
 * Migration Error Codes:
 * M1: Crab V2 Address already set
 * M2: Migration already happened
 * M3: Migration has not yet happened
 * M4: msg.sender is not Euler Mainnet Contract
 * M5: msg. sender cannot send ETH
 * M6: Can't withdraw more than you own
 * M7: Not enough ETH to repay the loan
 * M8: _ethToBorrow or _withdrawMaxEthToPay can't be 0
 * M9: invalid crabV2 address
 * M10: crab v2 address not yet set
 * M11: Wrong migration function, use flashMigrateAndWithdrawFromV1toV2
 * M12: Wrong migration function, use flashMigrateFromV1toV2
 */

/**
 * @dev CrabMigration contract
 * @notice Contract for Migrating from Crab v1 to Crab v2
 * @author Opyn team
 */
contract CrabMigration is Ownable {
    using SafeERC20 for IERC20;
    using StrategyMath for uint256;
    using Address for address payable;

    mapping(address => uint256) public sharesDeposited;
    bool public isMigrated;

    address payable public crabV1;
    address payable public crabV2;
    address public immutable euler;
    address public immutable weth;

    address immutable EULER_MAINNET;
    address immutable dToken;
    address immutable wPowerPerp;

    struct FlashloanCallbackData {
        address caller;
        uint256 amountToBorrow;
        uint8 callSource;
        bytes callData;
    }

    struct BatchMigrate {
        uint256 strategyCap;
    }

    struct FlashMigrateV1toV2 {
        uint256 v1oSqthToPay;
        uint256 ethToFlashDeposit;
        uint256 crabV1ToWithdraw;
        uint24 poolFee;
    }

    struct FlashMigrateAndBuyV1toV2 {
        uint256 v1oSqthToPay;
        uint256 ethToFlashDeposit;
        uint256 withdrawMaxEthToPay;
        uint256 crabV1ToWithdraw;
        uint24 poolFeeFlashDeposit;
    }

    enum FLASH_SOURCE {
        BATCH_MIGRATE,
        FLASH_MIGRATE_V1_TO_V2,
        FLASH_MIGRATE_WITHDRAW_V1_TO_V2
    }

    event ClaimAndWithdraw(address indexed user, uint256 crabAmount);
    event DepositV1Shares(address indexed user, uint256 crabV1Amount);
    event ClaimV2Shares(address indexed user, uint256 crabAmount);
    event FlashMigrate(address indexed user, uint256 crabV1Amount, uint256 crabV2Amount, uint256 excessEth);

    event WithdrawV1Shares(address indexed user, uint256 crabV1Amount);

    modifier beforeMigration() {
        require(!isMigrated, "M2");
        _;
    }

    modifier afterMigration() {
        require(isMigrated, "M3");
        _;
    }

    modifier afterInitialized() {
        require(crabV2 != address(0), "M8");
        _;
    }

    /**
     * @notice migration constructor
     * @param _crabV1 address of crab v1
     * @param _weth address of weth
     * @param _eulerExec address of euler exec contract
     * @param _dToken address of euler deposit token
     * @param _eulerMainnet address of euler deployment on mainnet
     */
    constructor(
        address payable _crabV1,
        address _weth,
        address _eulerExec,
        address _dToken,
        address _eulerMainnet
    ) {
        crabV1 = _crabV1;
        euler = _eulerExec;
        EULER_MAINNET = _eulerMainnet;
        weth = _weth;
        dToken = _dToken;
        wPowerPerp = CrabStrategy(crabV1).wPowerPerp();
        WETH9(_weth).approve(_eulerMainnet, type(uint256).max);
    }

    /**
     * @notice set the crabV2 address
     * @param _crabV2 address of crab v2
     */
    function setCrabV2(address payable _crabV2) external onlyOwner {
        require(crabV2 == address(0), "M1");
        require(_crabV2 != address(0), "M9");
        crabV2 = _crabV2;
    }

    /**
     * @notice allows users to deposit their crab v1 shares in the pool for migration
     */
    function depositV1Shares(uint256 amount) external beforeMigration {
        sharesDeposited[msg.sender] += amount;

        CrabStrategy(crabV1).transferFrom(msg.sender, address(this), amount);

        emit DepositV1Shares(msg.sender, amount);
    }

    /**
     * @notice allows users to withdraw their crab v1 shares in the pool before migration
     * @param amount amount of V1 shares to withdraw
     */
    function withdrawV1Shares(uint256 amount) external beforeMigration {
        sharesDeposited[msg.sender] = sharesDeposited[msg.sender].sub(amount);
        CrabStrategy(crabV1).transfer(msg.sender, amount);

        emit WithdrawV1Shares(msg.sender, amount);
    }

    /**
     * @notice the owner batch migrates all the crab v1 shares in this contract to crab v2 and initializes
     * the v2 contract at the same collateral ratio as the v1 contract.
     */
    function batchMigrate(uint256 _strategyCap) external onlyOwner afterInitialized beforeMigration {
        // 1. update isMigrated
        isMigrated = true;

        // 2. flash floan eth from euler eq to amt
        uint256 crabV1Balance = CrabStrategy(crabV1).balanceOf(address(this));
        uint256 crabV1Supply = CrabStrategy(crabV1).totalSupply();
        (, , uint256 totalCollateral, ) = CrabStrategy(crabV1).getVaultDetails();
        uint256 amountEthToBorrow = totalCollateral.wmul(crabV1Balance.wdiv(crabV1Supply));
        IEulerExec(euler).deferLiquidityCheck(
            address(this),
            abi.encode(
                FlashloanCallbackData({
                    caller: msg.sender,
                    amountToBorrow: amountEthToBorrow,
                    callSource: uint8(FLASH_SOURCE.BATCH_MIGRATE),
                    callData: abi.encode(BatchMigrate({strategyCap: _strategyCap}))
                })
            )
        );
    }

    function onDeferredLiquidityCheck(bytes memory encodedData) external afterInitialized {
        require(msg.sender == EULER_MAINNET, "M4");

        FlashloanCallbackData memory data = abi.decode(encodedData, (FlashloanCallbackData));

        // 1. Borrow weth
        IDToken(dToken).borrow(0, data.amountToBorrow);
        WETH9(weth).withdraw(data.amountToBorrow);

        // 2. Callback
        _flashCallback(data.caller, data.amountToBorrow, data.callSource, data.callData);

        // 3. Repay the weth:
        WETH9(weth).deposit{value: data.amountToBorrow}();
        IDToken(dToken).repay(0, data.amountToBorrow);
    }

    function _flashCallback(
        address _initiator,
        uint256 _amount,
        uint8 _callSource,
        bytes memory _calldata
    ) internal {
        if (FLASH_SOURCE(_callSource) == FLASH_SOURCE.BATCH_MIGRATE) {
            BatchMigrate memory data = abi.decode(_calldata, (BatchMigrate));

            uint256 crabV1Balance = CrabStrategy(crabV1).balanceOf(address(this));

            // 2. mint osqth in crab v2
            uint256 wSqueethToMint = CrabStrategy(crabV1).getWsqueethFromCrabAmount(crabV1Balance);
            uint256 timeAtLastHedge = CrabStrategy(crabV1).timeAtLastHedge();
            uint256 priceAtLastHedge = CrabStrategy(crabV1).priceAtLastHedge();
            CrabStrategyV2(crabV2).initialize{value: _amount}(
                wSqueethToMint,
                crabV1Balance,
                timeAtLastHedge,
                priceAtLastHedge,
                data.strategyCap
            );

            // 3. call withdraw from crab v1
            IERC20(wPowerPerp).approve(crabV1, type(uint256).max);
            CrabStrategy(crabV1).withdraw(crabV1Balance);
        } else if (FLASH_SOURCE(_callSource) == FLASH_SOURCE.FLASH_MIGRATE_V1_TO_V2) {
            FlashMigrateV1toV2 memory data = abi.decode(_calldata, (FlashMigrateV1toV2));

            CrabStrategyV2(crabV2).deposit{value: _amount}();

            CrabStrategy(crabV1).transferFrom(_initiator, address(this), data.crabV1ToWithdraw);

            IERC20(wPowerPerp).approve(crabV1, data.v1oSqthToPay);
            CrabStrategy(crabV1).withdraw(data.crabV1ToWithdraw);

            // Flash deposit remaining ETH, if user said so. Else return back the ETH. If CR1 = CR2 ethToFlashDeposit should be 0
            if (data.ethToFlashDeposit > 0) {
                CrabStrategyV2(crabV2).flashDeposit{value: address(this).balance.sub(_amount)}(
                    data.ethToFlashDeposit,
                    data.poolFee
                );
            }

            uint256 crabV2Amount = CrabStrategyV2(crabV2).balanceOf(address(this));
            // Sent back the V2 tokens to the user
            CrabStrategyV2(crabV2).transfer(_initiator, crabV2Amount);
            IERC20(wPowerPerp).transfer(_initiator, IERC20(wPowerPerp).balanceOf(address(this)));

            uint256 excessEth = address(this).balance;

            emit FlashMigrate(_initiator, data.crabV1ToWithdraw, crabV2Amount, excessEth.sub(_amount));

            // Sent back the excess ETH
            if (excessEth > _amount) {
                payable(_initiator).sendValue(excessEth.sub(_amount));
            }
        } else if (FLASH_SOURCE(_callSource) == FLASH_SOURCE.FLASH_MIGRATE_WITHDRAW_V1_TO_V2) {
            FlashMigrateAndBuyV1toV2 memory data = abi.decode(_calldata, (FlashMigrateAndBuyV1toV2));
            (, , , uint256 v1Short) = CrabStrategy(crabV1).getVaultDetails();

            CrabStrategy(crabV1).transferFrom(_initiator, address(this), data.crabV1ToWithdraw);
            CrabStrategyV2(crabV2).deposit{value: _amount}();

            uint256 oSqthToPay = IERC20(wPowerPerp).balanceOf(address(this));
            IERC20(wPowerPerp).approve(crabV1, oSqthToPay);

            // Find crab amount for contract's sqth balance. Remaining crab sould be withdrawn using flash withdraw
            uint256 crabV1ToWithdrawRmul = oSqthToPay.wmul(CrabStrategy(crabV1).totalSupply()).rdiv(v1Short);
            uint256 crabV1ToWithdraw = crabV1ToWithdrawRmul.floor(10**9) / (10**9);

            CrabStrategy(crabV1).withdraw(crabV1ToWithdraw);

            CrabStrategy(crabV1).flashWithdraw(data.crabV1ToWithdraw.sub(crabV1ToWithdraw), data.withdrawMaxEthToPay);
            require(address(this).balance >= _amount, "M7");

            if (data.ethToFlashDeposit > 0) {
                CrabStrategyV2(crabV2).flashDeposit{value: address(this).balance.sub(_amount)}(
                    data.ethToFlashDeposit,
                    data.poolFeeFlashDeposit
                );
            }

            uint256 crabV2Amount = CrabStrategyV2(crabV2).balanceOf(address(this));

            // Sent back the V2 tokens to the user
            CrabStrategyV2(crabV2).transfer(_initiator, crabV2Amount);
            IERC20(wPowerPerp).transfer(_initiator, IERC20(wPowerPerp).balanceOf(address(this)));

            uint256 excessEth = address(this).balance;

            emit FlashMigrate(_initiator, data.crabV1ToWithdraw, crabV2Amount, excessEth.sub(_amount));

            // Sent back the excess ETH
            if (excessEth > _amount) {
                payable(_initiator).sendValue(excessEth.sub(_amount));
            }
        }
    }

    /**
     * @notice allows users to claim their amount of crab v2 shares
     */
    function claimV2Shares() external afterMigration {
        uint256 amountV1Deposited = sharesDeposited[msg.sender];
        sharesDeposited[msg.sender] = 0;
        CrabStrategyV2(crabV2).transfer(msg.sender, amountV1Deposited);
        emit ClaimV2Shares(msg.sender, amountV1Deposited);
    }

    /**
     * @notice allows users to claim crabV2 shares and flash withdraw from crabV2
     *
     * @param _amountToWithdraw V2 shares to claim
     * @param _maxEthToPay maximum ETH to pay to buy back the owed wSqueeth debt
     */
    function claimAndWithdraw(
        uint256 _amountToWithdraw,
        uint256 _maxEthToPay,
        uint24 _poolFee
    ) external afterMigration {
        uint256 amountV1Deposited = sharesDeposited[msg.sender];
        require(_amountToWithdraw <= amountV1Deposited, "M6");

        sharesDeposited[msg.sender] = amountV1Deposited.sub(_amountToWithdraw);
        CrabStrategyV2(crabV2).flashWithdraw(_amountToWithdraw, _maxEthToPay, _poolFee);

        emit ClaimAndWithdraw(msg.sender, _amountToWithdraw);

        // Pay user's ETH back
        payable(msg.sender).sendValue(address(this).balance);
    }

    function flashMigrationDetails(uint256 _v1Shares)
        external
        view
        returns (
            bool,
            uint256,
            uint256,
            uint256
        )
    {
        return _flashMigrationDetails(_v1Shares);
    }

    /**
     * @notice Used to migrate from crab V1 to crab V2 when CR1 >= CR2
     *
     * @param _v1Shares V1 shares to migrate
     * @param _ethToFlashDeposit Flash deposit amount in crab v2 with excess ETH. If 0 will returned to sender
     */
    function flashMigrateFromV1toV2(
        uint256 _v1Shares,
        uint256 _ethToFlashDeposit,
        uint24 _poolFee
    ) external afterMigration {
        (bool isFlashOnlyMigrate, uint256 ethNeededForV2, uint256 v1oSqthToPay, ) = _flashMigrationDetails(_v1Shares);

        require(isFlashOnlyMigrate, "M11");

        IEulerExec(euler).deferLiquidityCheck(
            address(this),
            abi.encode(
                FlashloanCallbackData({
                    caller: msg.sender,
                    amountToBorrow: ethNeededForV2,
                    callSource: uint8(FLASH_SOURCE.FLASH_MIGRATE_V1_TO_V2),
                    callData: abi.encode(
                        FlashMigrateV1toV2({
                            v1oSqthToPay: v1oSqthToPay,
                            ethToFlashDeposit: _ethToFlashDeposit,
                            crabV1ToWithdraw: _v1Shares,
                            poolFee: _poolFee
                        })
                    )
                })
            )
        );
    }

    /**
     * @notice Used to migrate from crab V1 to crab V2 when CR1 < CR2
     *
     * @param _v1Shares V1 shares to migrate
     * @param _ethToFlashDeposit Flash deposit amount in crab v2 with excess ETH. If 0 will returned to sender
     * @param _ethToBorrow Amount to flash loan to deposit in crab v2
     * @param _withdrawMaxEthToPay maximum ETH to pay to buy back the owed wSqueeth debt
     * @param _poolFee specify the uniswap pool fee for the optional flash deposit into crab v2
     */
    function flashMigrateAndWithdrawFromV1toV2(
        uint256 _v1Shares,
        uint256 _ethToFlashDeposit,
        uint256 _ethToBorrow,
        uint256 _withdrawMaxEthToPay,
        uint24 _poolFee
    ) external afterMigration {
        (bool isFlashOnlyMigrate, , uint256 v1oSqthToPay, ) = _flashMigrationDetails(_v1Shares);

        require(!isFlashOnlyMigrate, "M12");
        require(_ethToBorrow > 0 && _withdrawMaxEthToPay > 0, "M8");

        IEulerExec(euler).deferLiquidityCheck(
            address(this),
            abi.encode(
                FlashloanCallbackData({
                    caller: msg.sender,
                    amountToBorrow: _ethToBorrow,
                    callSource: uint8(FLASH_SOURCE.FLASH_MIGRATE_WITHDRAW_V1_TO_V2),
                    callData: abi.encode(
                        FlashMigrateAndBuyV1toV2({
                            withdrawMaxEthToPay: _withdrawMaxEthToPay,
                            ethToFlashDeposit: _ethToFlashDeposit,
                            v1oSqthToPay: v1oSqthToPay,
                            crabV1ToWithdraw: _v1Shares,
                            poolFeeFlashDeposit: _poolFee
                        })
                    )
                })
            )
        );
    }

    /**
     * @notice Get migration details for given amount of v1 shares
     */
    function _flashMigrationDetails(uint256 _v1Shares)
        internal
        view
        returns (
            bool,
            uint256,
            uint256,
            uint256
        )
    {
        (, , uint256 v1TotalCollateral, uint256 v1TotalShort) = CrabStrategy(crabV1).getVaultDetails();
        (, , uint256 v2TotalCollateral, uint256 v2TotalShort) = CrabStrategyV2(crabV2).getVaultDetails();

        uint256 v1oSqthToPay = v1TotalShort.wmul(_v1Shares).wdiv(CrabStrategy(crabV1).totalSupply());
        uint256 ethNeededForV2 = v1oSqthToPay.wmul(v2TotalCollateral).rdiv(v2TotalShort).ceil(10**9) / (10**9);
        uint256 ethToGetFromV1 = _v1Shares.wdiv(CrabStrategy(crabV1).totalSupply()).wmul(v1TotalCollateral);

        return (ethNeededForV2 <= ethToGetFromV1, ethNeededForV2, v1oSqthToPay, ethToGetFromV1);
    }

    /**
     * @notice receive function to allow ETH transfer to this contract
     */
    receive() external payable {
        require(msg.sender == weth || msg.sender == crabV1 || msg.sender == crabV2, "M5");
    }
}