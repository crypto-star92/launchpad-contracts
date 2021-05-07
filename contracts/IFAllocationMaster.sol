//SPDX-License-Identifier: MIT
pragma solidity ^0.8.4;

import '@openzeppelin/contracts/token/ERC20/ERC20.sol';
import '@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol';
import '@openzeppelin/contracts/access/Ownable.sol';
import 'hardhat/console.sol';

// IFAllocationMaster is responsible for persisting all launchpad state between project token sales
// in order for the sales to have clean, self-enclosed, one-time-use states.

// IFAllocationMaster is the master of allocations. He can remember everything and he is a smart guy.
contract IFAllocationMaster is Ownable {
    using SafeERC20 for ERC20;

    // STRUCTS

    // A checkpoint for marking stake info at a given block
    struct UserCheckpoint {
        // block number of checkpoint
        uint256 blockNumber;
        // amount staked at checkpoint
        uint256 staked;
        // amount of stake weight at checkpoint
        uint256 stakeWeight;
        // number of finished sales at time of checkpoint
        uint24 numFinishedSales;
    }

    // A checkpoint for marking stake info at a given block
    struct TrackCheckpoint {
        // block number of checkpoint
        uint256 blockNumber;
        // amount staked at checkpoint
        uint256 totalStaked;
        // amount of stake weight at checkpoint
        uint256 totalStakeWeight;
        // number of finished sales at time of checkpoint
        uint24 numFinishedSales;
        // record checkpoint number in struct
        uint32 checkpointNumber;
        // whether track is disabled (once disabled, cannot undo)
        bool disabled;
    }

    // Info of each track. These parameters cannot be changed.
    struct TrackInfo {
        // name of track
        string name;
        // token to stake (IDIA)
        ERC20 stakeToken;
        // weight accrual rate for this track (stake weight increase per block per stake token)
        uint80 weightAccrualRate;
    }

    // INFO FOR FACTORING IN ROLLOVERS

    // the number of checkpoints of a track -- (track, finished sale number) => block number
    mapping(uint256 => mapping(uint24 => uint256))
        public trackFinishedSaleBlocks;

    // TRACK INFO

    // array of track information
    TrackInfo[] public tracks;

    // the number of checkpoints of a track -- (track) => checkpoint count
    mapping(uint256 => uint32) public trackCheckpointCounts;

    // track checkpoint mapping -- (track, checkpoint number) => TrackCheckpoint
    mapping(uint256 => mapping(uint32 => TrackCheckpoint))
        public trackCheckpoints;

    // USER INFO

    // the number of checkpoints of a user for a track -- (track, user address) => checkpoint count
    mapping(uint256 => mapping(address => uint32)) public userCheckpointCounts;

    // user checkpoint mapping -- (track, user address, checkpoint number) => UserCheckpoint
    mapping(uint256 => mapping(address => mapping(uint32 => UserCheckpoint)))
        public userCheckpoints;

    // EVENTS

    event AddTrack(string indexed name, address indexed token);
    event DisableTrack(uint256 indexed trackId);
    event BumpSaleCounter(uint256 indexed trackId, uint32 newCount);
    event AddUserCheckpoint(uint256 blockNumber, uint256 indexed trackId);
    event AddTrackCheckpoint(uint256 blockNumber, uint256 indexed trackId);
    event Stake(address indexed user, uint256 indexed trackId, uint256 amount);
    event Unstake(
        address indexed user,
        uint256 indexed trackId,
        uint256 amount
    );

    // CONSTRUCTOR

    constructor() {}

    // FUNCTIONS

    // number of tracks
    function trackCount() external view returns (uint256) {
        return tracks.length;
    }

    // adds a new track
    function addTrack(
        string calldata name,
        ERC20 stakeToken,
        uint80 _weightAccrualRate
    ) public onlyOwner {
        // add track
        tracks.push(
            TrackInfo({
                name: name, // name of track
                stakeToken: stakeToken, // token to stake (e.g., IDIA)
                weightAccrualRate: _weightAccrualRate // rate of stake weight accrual
            })
        );

        // add first track checkpoint
        addTrackCheckpoint(
            tracks.length - 1, // latest track
            0, // initialize with 0 stake
            false, // add or sub does not matter
            false, // initialize as not disabled
            false // do not bump finished sale counter
        );

        // emit
        emit AddTrack(name, address(stakeToken));
    }

    // bumps a track's finished sale counter
    function bumpSaleCounter(uint256 trackId) public onlyOwner {
        // get number of finished sales of this track
        uint24 nFinishedSales =
            trackCheckpoints[trackId][trackCheckpointCounts[trackId] - 1]
                .numFinishedSales;

        // update map that tracks block numbers of finished sales
        trackFinishedSaleBlocks[trackId][nFinishedSales] = block.number;

        // add a new checkpoint with counter incremented by 1
        addTrackCheckpoint(trackId, 0, false, false, true);

        // `BumpSaleCounter` event emitted in function call above
    }

    // disables a track
    function disableTrack(uint256 trackId) public onlyOwner {
        // add a new checkpoint with `disabled` set to true
        addTrackCheckpoint(trackId, 0, false, true, false);

        // `DisableTrack` event emitted in function call above
    }

    // get closest PRECEDING user checkpoint
    function getClosestUserCheckpoint(
        uint256 trackId,
        address user,
        uint256 blockNumber
    ) private view returns (UserCheckpoint memory cp) {
        // get total checkpoint count for user
        uint32 nCheckpoints = userCheckpointCounts[trackId][user];

        if (
            userCheckpoints[trackId][user][nCheckpoints - 1].blockNumber <=
            blockNumber
        ) {
            // First check most recent checkpoint

            // return closest checkpoint
            return userCheckpoints[trackId][user][nCheckpoints - 1];
        } else if (
            userCheckpoints[trackId][user][0].blockNumber > blockNumber
        ) {
            // Next check earliest checkpoint

            // If specified block number is earlier than user's first checkpoint,
            // return null checkpoint
            return
                UserCheckpoint({
                    blockNumber: 0,
                    staked: 0,
                    stakeWeight: 0,
                    numFinishedSales: 0
                });
        } else {
            // binary search on checkpoints
            uint32 lower = 0;
            uint32 upper = nCheckpoints - 1;
            while (upper > lower) {
                uint32 center = upper - (upper - lower) / 2; // ceil, avoiding overflow
                UserCheckpoint memory tempCp =
                    userCheckpoints[trackId][user][center];
                if (tempCp.blockNumber == blockNumber) {
                    return tempCp;
                } else if (tempCp.blockNumber < blockNumber) {
                    lower = center;
                } else {
                    upper = center - 1;
                }
            }

            // return closest checkpoint
            return userCheckpoints[trackId][user][lower];
        }
    }

    // gets a user's stake weight within a track at a particular block number
    // logic extended from Compound COMP token `getPriorVotes` function
    function getUserStakeWeight(
        uint256 trackId,
        address user,
        uint256 blockNumber
    ) public view returns (uint256) {
        require(blockNumber <= block.number, 'block # too high');

        // check number of user checkpoints
        uint32 nUserCheckpoints = userCheckpointCounts[trackId][user];
        if (nUserCheckpoints == 0) {
            return 0;
        }

        // get closest preceding user checkpoint
        UserCheckpoint memory closestUserCheckpoint =
            getClosestUserCheckpoint(trackId, user, blockNumber);

        // check if closest preceding checkpoint was null checkpoint
        if (closestUserCheckpoint.blockNumber == 0) {
            return 0;
        }

        // get closest preceding track checkpoint
        TrackCheckpoint memory closestTrackCheckpoint =
            getClosestTrackCheckpoint(trackId, blockNumber);

        // get number of finished sales between user's last checkpoint blockNumber and provided blockNumber
        uint24 numFinishedSalesDelta =
            closestTrackCheckpoint.numFinishedSales -
                closestUserCheckpoint.numFinishedSales;

        // get track's weight accrual rate
        uint80 weightAccrualRate = tracks[trackId].weightAccrualRate;

        // calculate stake weight given above delta
        uint256 stakeWeight;
        if (numFinishedSalesDelta == 0) {
            // calculate normally without rollover decay

            uint256 elapsedBlocks =
                blockNumber - closestUserCheckpoint.blockNumber;

            stakeWeight =
                closestUserCheckpoint.stakeWeight +
                (elapsedBlocks *
                    weightAccrualRate *
                    closestUserCheckpoint.staked) /
                10**18;

            return stakeWeight;
        } else {
            // calculate with rollover decay

            // starting stakeweight
            stakeWeight = closestUserCheckpoint.stakeWeight;
            // current block for iteration
            uint256 currBlock = closestUserCheckpoint.blockNumber;

            // for each finished sale in between, get stake weight of that period
            // and perform weighted sum
            for (uint24 i = 0; i < numFinishedSalesDelta; i++) {
                // get number of blocks passed at the current sale number
                uint256 elapsedBlocks =
                    trackFinishedSaleBlocks[trackId][
                        closestUserCheckpoint.numFinishedSales + i
                    ] - currBlock;

                // update stake weight
                stakeWeight =
                    stakeWeight +
                    (elapsedBlocks *
                        weightAccrualRate *
                        closestUserCheckpoint.staked) /
                    10**18;

                // factor in decay
                stakeWeight = stakeWeight / 5;

                // update currBlock for next round
                currBlock = trackFinishedSaleBlocks[trackId][
                    closestUserCheckpoint.numFinishedSales + i
                ];
            }

            // add any remaining accrued stake weight at current finished sale count
            uint256 remainingElapsed =
                blockNumber -
                    trackFinishedSaleBlocks[trackId][
                        closestTrackCheckpoint.numFinishedSales - 1
                    ];
            stakeWeight +=
                (remainingElapsed *
                    weightAccrualRate *
                    closestUserCheckpoint.staked) /
                10**18;
        }

        // return
        return stakeWeight;
    }

    // get closest PRECEDING track checkpoint
    function getClosestTrackCheckpoint(uint256 trackId, uint256 blockNumber)
        private
        view
        returns (TrackCheckpoint memory cp)
    {
        // get total checkpoint count for track
        uint32 nCheckpoints = trackCheckpointCounts[trackId];

        if (
            trackCheckpoints[trackId][nCheckpoints - 1].blockNumber <=
            blockNumber
        ) {
            // First check most recent checkpoint

            // return closest checkpoint
            return trackCheckpoints[trackId][nCheckpoints - 1];
        } else if (trackCheckpoints[trackId][0].blockNumber > blockNumber) {
            // Next check earliest checkpoint

            // If specified block number is earlier than track's first checkpoint,
            // return null checkpoint
            return
                TrackCheckpoint({
                    blockNumber: 0,
                    totalStaked: 0,
                    totalStakeWeight: 0,
                    disabled: false,
                    numFinishedSales: 0,
                    checkpointNumber: 0
                });
        } else {
            // binary search on checkpoints
            uint32 lower = 0;
            uint32 upper = nCheckpoints - 1;
            while (upper > lower) {
                uint32 center = upper - (upper - lower) / 2; // ceil, avoiding overflow
                TrackCheckpoint memory tempCp =
                    trackCheckpoints[trackId][center];
                if (tempCp.blockNumber == blockNumber) {
                    return tempCp;
                } else if (tempCp.blockNumber < blockNumber) {
                    lower = center;
                } else {
                    upper = center - 1;
                }
            }

            // return closest checkpoint
            return trackCheckpoints[trackId][lower];
        }
    }

    // gets total stake weight within a track at a particular block number
    // logic extended from Compound COMP token `getPriorVotes` function
    function getTotalStakeWeight(uint256 trackId, uint256 blockNumber)
        public
        view
        returns (uint256)
    {
        require(blockNumber <= block.number, 'block # too high');

        // get closest track checkpoint
        TrackCheckpoint memory closestCheckpoint =
            getClosestTrackCheckpoint(trackId, blockNumber);

        // calculate blocks elapsed since checkpoint
        uint256 additionalBlocks =
            (blockNumber - closestCheckpoint.blockNumber);

        // get track info
        TrackInfo storage trackInfo = tracks[trackId];

        // calculate marginal accrued stake weight
        uint256 marginalAccruedStakeWeight =
            (additionalBlocks *
                trackInfo.weightAccrualRate *
                closestCheckpoint.totalStaked) / 10**18;

        // debug
        // console.log('total stake weight');
        // console.log(
        //     block.number,
        //     closestCheckpoint.totalStakeWeight,
        //     '+',
        //     marginalAccruedStakeWeight
        // );

        // return
        return closestCheckpoint.totalStakeWeight + marginalAccruedStakeWeight;
    }

    function addUserCheckpoint(
        uint256 trackId,
        uint256 amount,
        bool addElseSub
    ) internal {
        // get user checkpoint count
        uint32 nCheckpointsUser = userCheckpointCounts[trackId][_msgSender()];

        // get track checkpoint count
        uint32 nCheckpointsTrack = trackCheckpointCounts[trackId];

        // get latest track checkpoint
        TrackCheckpoint memory trackCp =
            trackCheckpoints[trackId][nCheckpointsTrack - 1];

        // if this is first checkpoint
        if (nCheckpointsUser == 0) {
            // console.log(
            //     '---- adding user checkpoint',
            //     nCheckpoints,
            //     '(stake) ----'
            // );
            // console.log('block', block.number);
            // console.log('staked', amount);
            // console.log('weight', 0);
            // console.log('----');

            // add a first checkpoint for this user on this track
            userCheckpoints[trackId][_msgSender()][0] = UserCheckpoint({
                blockNumber: block.number,
                staked: amount,
                stakeWeight: 0,
                numFinishedSales: trackCp.numFinishedSales
            });
        } else {
            // get previous checkpoint
            UserCheckpoint storage prev =
                userCheckpoints[trackId][_msgSender()][nCheckpointsUser - 1];

            // add a new checkpoint for user within this track
            userCheckpoints[trackId][_msgSender()][
                nCheckpointsUser
            ] = UserCheckpoint({
                blockNumber: block.number,
                staked: addElseSub
                    ? prev.staked + amount
                    : prev.staked - amount,
                stakeWeight: getUserStakeWeight(
                    trackId,
                    _msgSender(),
                    block.number
                ),
                numFinishedSales: trackCp.numFinishedSales
            });

            // console.log(
            //     '---- adding user checkpoint',
            //     nCheckpoints,
            //     '(stake) ----'
            // );
            // console.log('block', block.number);
            // console.log('staked', prev.staked, '+', amount);
            // console.log(
            //     'weight',
            //     prev.stakeWeight,
            //     addElseSub ? '+' : '-',
            //     marginalAccruedStakeWeight
            // );
            // console.log('----');
        }

        // increment user's checkpoint count
        userCheckpointCounts[trackId][_msgSender()] = nCheckpointsUser + 1;

        // emit
        emit AddUserCheckpoint(block.number, trackId);
    }

    function addTrackCheckpoint(
        uint256 trackId, // track number
        uint256 amount, // delta on staked amount
        bool addElseSub, // true = adding; false = subtracting
        bool disabled, // whether track is disabled; cannot undo a disable
        bool _bumpSaleCounter // whether to increase sale counter by 1
    ) internal {
        // get track info
        TrackInfo storage track = tracks[trackId];

        // get track checkpoint count
        uint32 nCheckpoints = trackCheckpointCounts[trackId];

        // if this is first checkpoint
        if (nCheckpoints == 0) {
            // add a first checkpoint for this track
            trackCheckpoints[trackId][0] = TrackCheckpoint({
                blockNumber: block.number,
                totalStaked: amount,
                totalStakeWeight: 0,
                disabled: disabled,
                numFinishedSales: _bumpSaleCounter ? 1 : 0,
                checkpointNumber: 0
            });

            // console.log('---- adding track checkpoint', nCheckpoints, ' ----');
            // console.log('block', block.number);
            // console.log('total staked', amount);
            // console.log('total weight', 0);
            // console.log('----');
        } else {
            // get previous checkpoint
            TrackCheckpoint storage prev =
                trackCheckpoints[trackId][nCheckpoints - 1];

            // calculate blocks elapsed since checkpoint
            uint256 additionalBlocks = (block.number - prev.blockNumber);

            // calculate marginal accrued stake weight
            uint256 marginalAccruedStakeWeight =
                (additionalBlocks *
                    track.weightAccrualRate *
                    prev.totalStaked) / 10**18;

            // calculate new stake weight
            uint256 newStakeWeight =
                prev.totalStakeWeight + marginalAccruedStakeWeight;

            // factor in decay
            if (_bumpSaleCounter) {
                newStakeWeight = newStakeWeight / 5;
            }

            // console.log('---- adding track checkpoint', nCheckpoints, ' ----');
            // console.log('block', block.number);
            // console.log(
            //     'total staked',
            //     prev.totalStaked,
            //     addElseSub ? '+' : '-',
            //     amount
            // );
            // console.log(
            //     'total weight',
            //     prev.totalStakeWeight,
            //     '+',
            //     marginalAccruedStakeWeight
            // );
            // console.log('----');

            // add a new checkpoint for this track
            if (prev.disabled) {
                // if previous checkpoint was disabled, then total staked can only decrease
                require(addElseSub == false, 'disabled track can only sub');
                // if previous checkpoint was disabled, then disabled cannot be false going forward
                require(disabled == true, 'cannot undo disable');

                // if previous checkpoint was disabled, stakeweight cannot increase
                // and new checkpoint must also be disabled
                trackCheckpoints[trackId][nCheckpoints] = TrackCheckpoint({
                    blockNumber: block.number,
                    totalStaked: prev.totalStaked - amount,
                    totalStakeWeight: prev.totalStakeWeight,
                    disabled: true,
                    numFinishedSales: prev.numFinishedSales,
                    checkpointNumber: nCheckpoints
                });
            } else {
                trackCheckpoints[trackId][nCheckpoints] = TrackCheckpoint({
                    blockNumber: block.number,
                    totalStaked: addElseSub
                        ? prev.totalStaked + amount
                        : prev.totalStaked - amount,
                    totalStakeWeight: newStakeWeight,
                    disabled: disabled,
                    numFinishedSales: _bumpSaleCounter
                        ? prev.numFinishedSales + 1
                        : prev.numFinishedSales,
                    checkpointNumber: nCheckpoints
                });

                // emit
                if (_bumpSaleCounter) {
                    emit BumpSaleCounter(trackId, prev.numFinishedSales + 1);
                }
                if (disabled) {
                    emit DisableTrack(trackId);
                }
            }
        }

        // increase new track's checkpoint count by 1
        trackCheckpointCounts[trackId]++;

        // emit
        emit AddTrackCheckpoint(block.number, trackId);
    }

    // stake
    function stake(uint256 trackId, uint256 amount) external {
        // stake amount must be greater than 0
        require(amount > 0, 'amount is 0');

        // get track info
        TrackInfo storage track = tracks[trackId];

        // get latest track checkpoint
        TrackCheckpoint storage checkpoint =
            trackCheckpoints[trackId][trackCheckpointCounts[trackId]];

        // cannot stake into disabled track
        require(!checkpoint.disabled, 'track is disabled');

        // transfer the specified amount of stake token from user to this contract
        track.stakeToken.safeTransferFrom(_msgSender(), address(this), amount);

        // add user checkpoint
        addUserCheckpoint(trackId, amount, true);

        // add track checkpoint
        addTrackCheckpoint(trackId, amount, true, false, false);

        // emit
        emit Stake(_msgSender(), trackId, amount);
    }

    // unstake
    function unstake(uint256 trackId, uint256 amount) external {
        // amount must be greater than 0
        require(amount > 0, 'amount is 0');

        // get track info
        TrackInfo storage track = tracks[trackId];

        // get number of user's checkpoints within this track
        uint32 userCheckpointCount =
            userCheckpointCounts[trackId][_msgSender()];

        // get user's latest checkpoint
        UserCheckpoint storage checkpoint =
            userCheckpoints[trackId][_msgSender()][userCheckpointCount - 1];

        // ensure amount <= user's current stake
        require(amount <= checkpoint.staked, 'amount > staked');

        // transfer the specified amount of stake token from this contract to user
        track.stakeToken.safeTransfer(_msgSender(), amount);

        // add user checkpoint
        addUserCheckpoint(trackId, amount, false);

        // add track checkpoint
        addTrackCheckpoint(trackId, amount, false, false, false);

        // emit
        emit Unstake(_msgSender(), trackId, amount);
    }
}
