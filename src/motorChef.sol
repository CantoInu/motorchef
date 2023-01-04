// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

import {Owned} from "solmate/auth/Owned.sol";
import {ReentrancyGuard} from "solmate/utils/ReentrancyGuard.sol";
import {SafeTransferLib} from "solmate/utils/SafeTransferLib.sol";
import {ERC20} from "solmate/tokens/ERC20.sol";

import {Comptroller, CToken} from "clm/Comptroller.sol";
import {WETH} from "clm/WETH.sol";

import {ExponentialNoError as fpMath} from "./ExponentialNoError.sol";

interface LPPair {
    function claimFees() external returns (uint claimed0, uint claimed1);
    function token0() external view returns (address);
    function token1() external view returns (address);
}

contract MotorChef is Owned(msg.sender), ReentrancyGuard {

    Comptroller public constant comptroller = Comptroller(0x5E23dC409Fc2F832f83CEc191E245A191a4bCc5C);
    WETH        public constant weth = WETH(payable(0x826551890Dc65655a0Aceca109aB11AbDbD7a07B));
    address     public constant lpPair = 0x42A515C472b3B953beb8ab68aDD27f4bA3792451;

    // Info of each user.
    struct UserInfo {
        uint256 amount; // How many LP tokens the user has provided.
        uint256 rewardDebt; // Reward debt. See explanation below.
        //
        // We do some fancy math here. Basically, any point in time, the amount of CANTOs
        // entitled to a user but is pending to be distributed is:
        //
        //   pending reward = (user.amount * pool.accCantoPerShare) - user.rewardDebt
        //
        // Whenever a user deposits or withdraws LP tokens to a pool. Here's what happens:
        //   1. The pool's `accCantoPerShare` (and `lastRewardBlock`) gets updated.
        //   2. User receives the pending reward sent to his/her address.
        //   3. User's `amount` gets updated.
        //   4. User's `rewardDebt` gets updated.
    }

    // Info of each pool.
    struct PoolInfo {
        ERC20 lpToken; // Address of LP token contract.
        uint256 allocPoint; // How many allocation points assigned to this pool. CANTOs to distribute per block.
        uint256 lastRewardBlock; // Last block number that CANTOs distribution occurs.
        uint256 accCantoPerShare; // Accumulated CANTO per share, times 1e12. See below.
    }

    CToken[] public cTokenInfo;

    // Info of each pool.
    PoolInfo[] public poolInfo;
    // Info of each user that stakes LP tokens.
    mapping(uint256 => mapping(address => UserInfo)) public userInfo;
    // Total allocation poitns. Must be the sum of all allocation points in all pools.
    uint256 public totalAllocPoint = 0;
    // The block number when CANTO mining starts.
    uint256 public startBlock;
    event Deposit(address indexed user, uint256 indexed pid, uint256 amount);
    event Withdraw(address indexed user, uint256 indexed pid, uint256 amount);
    event EmergencyWithdraw(
        address indexed user,
        uint256 indexed pid,
        uint256 amount
    );

    constructor(
        uint256 _startBlock
    ) {
        startBlock = _startBlock;
        cTokenInfo.push(CToken(0x3C96dCfd875253A37acB3D2B102b6f328349b16B)); //cCantoNoteLP
        cTokenInfo.push(CToken(0xC0D6574b2fe71eED8Cd305df0DA2323237322557)); //cCantoAtomLP
        cTokenInfo.push(CToken(0xb49A395B39A0b410675406bEE7bD06330CB503E3)); //cCantoETHLP
        add(100, ERC20(lpPair), false);  //cINU/WCANTO pair
    }

    function poolLength() external view returns (uint256) {
        return poolInfo.length;
    }

    // Add a new lp to the pool. Can only be called by the owner.
    // XXX DO NOT add the same LP token more than once. Rewards will be messed up if you do.
    function add(
        uint256 _allocPoint,
        ERC20 _lpToken,
        bool _withUpdate
    ) public onlyOwner {
        if (_withUpdate) {
            massUpdatePools();
        }
        uint256 lastRewardBlock =
            block.number > startBlock ? block.number : startBlock;
        totalAllocPoint += _allocPoint;
        poolInfo.push(
            PoolInfo({
                lpToken: _lpToken,
                allocPoint: _allocPoint,
                lastRewardBlock: lastRewardBlock,
                accCantoPerShare: 0
            })
        );
    }

    // Update the given pool's CANTO allocation point. Can only be called by the owner.
    function set(
        uint256 _pid,
        uint256 _allocPoint,
        bool _withUpdate
    ) public onlyOwner {
        if (_withUpdate) {
            massUpdatePools();
        }
        totalAllocPoint -= poolInfo[_pid].allocPoint - _allocPoint;
        poolInfo[_pid].allocPoint = _allocPoint;
    }


    //View function that calculates the updated delta
    function updateStateIndex(uint224 idx, uint32 lastBlock, CToken token) internal view returns (uint224) {
        uint256 deltaBlocks = block.number - uint256(lastBlock);

        if(deltaBlocks > 0) {
            uint256 compAccrued = fpMath.mul_(deltaBlocks, comptroller.compSupplySpeeds(address(token)));
            fpMath.Double memory ratio = fpMath.fraction(compAccrued, token.totalSupply());
            return uint224(fpMath.add_(fpMath.Double({mantissa: idx}), ratio).mantissa);
        } else {
            return idx;
        }
    }


    //View function to get full pending CANTO due to this contract
    function getPendingWCANTO(CToken cToken) public view returns (uint256) {
        (uint224 idx, uint32 lastBlock) = comptroller.compSupplyState(address(cToken));
        uint256 supplierIdx = comptroller.compSupplierIndex(address(cToken), address(this));

        // adjust for latest info
        idx = updateStateIndex(idx, lastBlock, cToken);

        fpMath.Double memory deltaIndex =
            fpMath.Double({mantissa: fpMath.sub_(idx, supplierIdx)});

        uint256 supplierDelta = fpMath.mul_(
            cToken.balanceOf(address(this)), 
            deltaIndex
        );

        return supplierDelta;

    }

    // View function to see pending CANTOs on frontend.
    function pendingCanto(uint256 _pid, address _user, uint256 _cTokenIdx)
        external
        view
        returns (uint256)
    {
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][_user];
        uint256 accCantoPerShare = pool.accCantoPerShare;
        uint256 lpSupply = pool.lpToken.balanceOf(address(this));
        if (block.number > pool.lastRewardBlock && lpSupply != 0) {
            uint256 cantoReward =
                getPendingWCANTO(cTokenInfo[_cTokenIdx]) * pool.allocPoint / 
                    totalAllocPoint;
            accCantoPerShare += (
                cantoReward * 1e12 / 
                    lpSupply
            );
        }
        return ((user.amount * accCantoPerShare) / 1e12) - user.rewardDebt;
    }

    
    // Update reward vairables for all pools. Be careful of gas spending!
    function massUpdatePools() public {
        uint256 length = poolInfo.length;
        unchecked{
            for (uint256 pid = 0; pid < length; ++pid) {
                    updatePool(pid);
            }
        }
    }

    // Update reward variables of the given pool to be up-to-date.
    function updatePool(uint256 _pid) public nonReentrant {
        PoolInfo storage pool = poolInfo[_pid];
        if (block.number <= pool.lastRewardBlock) {
            return;
        }
        uint256 lpSupply = pool.lpToken.balanceOf(address(this));
        if (lpSupply == 0) {
            pool.lastRewardBlock = block.number;
            return;
        }                
        uint256 cantoReward;
        // Can't realistically overflow
        unchecked{
            for (uint256 i; i<cTokenInfo.length; ++i) {
                cantoReward += getPendingWCANTO(cTokenInfo[i]) * pool.allocPoint / 
                    totalAllocPoint;
            }
        }
        address[] memory addr = new address[](1);
        addr[0] = address(this);
        comptroller.claimComp(addr, cTokenInfo, false, true);
        pool.accCantoPerShare += cantoReward * 1e12 / lpSupply;
        pool.lastRewardBlock = block.number;
    }

    // Deposit LP tokens to MotorChef for WCANTO allocation.
    function deposit(uint256 _pid, uint256 _amount) public {
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][msg.sender];
        updatePool(_pid);
        if (user.amount > 0) {
            uint256 pending =
                user.amount * pool.accCantoPerShare / 1e12 -
                    user.rewardDebt;
            safeWCANTOTransfer(msg.sender, pending);
        }
        SafeTransferLib.safeTransferFrom(
            ERC20(pool.lpToken),
            address(msg.sender),
            address(this),
            _amount
        );
        user.amount += _amount;
        user.rewardDebt = user.amount * pool.accCantoPerShare / 1e12;
        emit Deposit(msg.sender, _pid, _amount);
    }

    // Withdraw LP tokens from MasterChef.
    function withdraw(uint256 _pid, uint256 _amount) public {
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][msg.sender];
        require(user.amount >= _amount, "withdraw: not good");
        updatePool(_pid);
        uint256 pending =
            user.amount * pool.accCantoPerShare / 1e12 -
                user.rewardDebt;
        safeWCANTOTransfer(msg.sender, pending);
        user.amount -= _amount;
        user.rewardDebt = user.amount * pool.accCantoPerShare / 1e12;
        SafeTransferLib.safeTransferFrom(
            pool.lpToken,
            address(this),
            address(msg.sender),
            _amount
        );
        emit Withdraw(msg.sender, _pid, _amount);
    }

    // Withdraw without caring about rewards. EMERGENCY ONLY.
    function emergencyWithdraw(uint256 _pid) public {
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][msg.sender];
        SafeTransferLib.safeTransferFrom(
            pool.lpToken,
            address(this),
            address(msg.sender),
            user.amount
        );
        emit EmergencyWithdraw(msg.sender, _pid, user.amount);
        user.amount = 0;
        user.rewardDebt = 0;
    }

    // Safe wcanto transfer function, just in case if rounding error causes pool to not have enough CANTOs.
    function safeWCANTOTransfer(address _to, uint256 _amount) internal {
        uint256 wethBal = weth.balanceOf(address(this));
        if (_amount > wethBal) {
            weth.transfer(_to, wethBal);
        } else {
            weth.transfer(_to, _amount);
        }
    }

    function addCToken(address cToken) public onlyOwner {
        bool _exists;
        uint256 i;
        while (!_exists && i<cTokenInfo.length) {
            if(cToken != address(cTokenInfo[i])) {
                return;
            }
        }
        cTokenInfo.push(CToken(cToken));

    }

    function retrieveCToken(address cToken) public onlyOwner {
        CToken token = CToken(cToken);
        uint256 bal = token.balanceOf(address(this));
        token.transfer(msg.sender, bal);
    }

    // owner can claim LP fees from Forteswap pair
    function claimLPFees(uint256 pid) public onlyOwner {
        LPPair lp = LPPair(address(poolInfo[pid].lpToken));
        (uint claimed0, uint claimed1) = LPPair(lp).claimFees();
        
        //transfer with error handling if we hold less than the claimed amount
        // this approach has the risk that we have too many assets in here if claimed is understated, 
        // but this approach removes the possibility of sweeping WETH due to stakers
        ERC20(lp.token0()).transfer(
            msg.sender, 
            claimed0 > ERC20(lp.token0()).balanceOf(address(this))? 
                ERC20(lp.token0()).balanceOf(address(this)) : 
                claimed0
        );
        ERC20(lp.token1()).transfer(
            msg.sender, 
            claimed1 > ERC20(lp.token1()).balanceOf(address(this))? 
                ERC20(lp.token1()).balanceOf(address(this)) : 
                claimed1
        );
    }
}