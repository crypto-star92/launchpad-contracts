import '@nomiclabs/hardhat-ethers'
import { ethers } from 'hardhat'
import { expect } from 'chai'
import { SignerWithAddress } from '@nomiclabs/hardhat-ethers/signers'
import { Contract } from '@ethersproject/contracts'
import { asyncWriteFile, mineNext, readFile, unparseCsv } from './helpers'
import { simAllocationMaster } from './simulator'

import sim1Input from './simulationData/sim1Input.json'
import sim2Input from './simulationData/sim2Input.json'
import sim3Input from './simulationData/sim3Input.json'
import sim4Input from './simulationData/sim4Input.json'

// array of simulations input/output maps
const simulations = [
  { in: sim1Input, out: './test/simulationData/sim1ExpectedOutput.csv' },
  { in: sim2Input, out: './test/simulationData/sim2ExpectedOutput.csv' },
  { in: sim3Input, out: './test/simulationData/sim3ExpectedOutput.csv' },
  { in: sim4Input, out: './test/simulationData/sim4ExpectedOutput.csv' }
]

export default describe('IFAllocationMaster', function () {
  // unset timeout from the test
  this.timeout(0)

  // vars for all tests
  let owner: SignerWithAddress
  let nonOwner: SignerWithAddress
  let simUser1: SignerWithAddress
  let simUser2: SignerWithAddress
  let TestToken: Contract
  let IFAllocationMaster: Contract

  // setup for each test
  beforeEach(async () => {
    // get test accounts
    owner = (await ethers.getSigners())[0]
    nonOwner = (await ethers.getSigners())[1]
    simUser1 = (await ethers.getSigners())[2]
    simUser2 = (await ethers.getSigners())[3]

    // deploy test token
    const TestTokenFactory = await ethers.getContractFactory('GenericToken')
    TestToken = await TestTokenFactory.deploy(
      'test token',
      'TEST',
      '21000000000000000000000000000' // 21 billion * 10**18
    )

    // deploy allocation master
    const IFAllocationMasterFactory = await ethers.getContractFactory(
      'IFAllocationMaster'
    )
    IFAllocationMaster = await IFAllocationMasterFactory.deploy(
      ethers.constants.AddressZero
    )
  })

  // TESTS

  it('counts tracks', async () => {
    // num tracks should be 0
    mineNext()
    expect(await IFAllocationMaster.trackCount()).to.equal(0)

    // add a track
    mineNext()
    await IFAllocationMaster.addTrack(
      'TEST Track', // name
      TestToken.address, // stake token
      1000, // weight accrual rate
      '100000000000000000', // passive rollover rate (10%)
      '200000000000000000', // active rollover rate (20%)
      '1000000000000000000000000000000' // max total stake (1 trillion)
    )

    // num tracks should be 1
    mineNext()
    expect(await IFAllocationMaster.trackCount()).to.equal(1)
  })

  it('can bump sale counter', async () => {
    // add a track
    mineNext()
    await IFAllocationMaster.addTrack(
      'TEST Track', // name
      TestToken.address, // stake token
      1000, // weight accrual rate
      '100000000000000000', // passive rollover rate (10%)
      '200000000000000000', // active rollover rate (20%)
      '1000000000000000000000000000000' // max total stake (1 trillion)
    )
    const trackNum = 0

    // bump sale counter
    mineNext()
    await IFAllocationMaster.bumpSaleCounter(trackNum)
    mineNext()

    // update track as non-owner (should fail)
    mineNext()
    await expect(IFAllocationMaster.connect(nonOwner).bumpSaleCounter(trackNum))
      .to.be.reverted
    mineNext()

    // sale counter should update only by owner
    const nTrackCheckpoints = await IFAllocationMaster.trackCheckpointCounts(
      trackNum
    )
    const latestTrackCp = await IFAllocationMaster.trackCheckpoints(
      trackNum,
      nTrackCheckpoints - 1
    )
    mineNext()
    expect(latestTrackCp.numFinishedSales).to.equal(1) // only 1 not 2

    //// user checkpoint should record latest sale count

    // approve
    await TestToken.approve(IFAllocationMaster.address, '1000')
    // stake
    await IFAllocationMaster.stake(trackNum, '1000')
    mineNext()

    // get newly generated checkpoint info
    const nUserCheckpoints = await IFAllocationMaster.userCheckpointCounts(
      trackNum,
      owner.address
    )
    const userCp = await IFAllocationMaster.userCheckpoints(
      trackNum,
      owner.address,
      nUserCheckpoints - 1
    )

    // new user checkpoint's numFinishedSales should match
    expect(userCp.numFinishedSales).to.equal(1)
  })

  it('simulation 1: general staking and unstaking', async () => {
    // allocate stake token to simulation user1 and user2
    mineNext()
    await TestToken.transfer(simUser1.address, '10000000000000000000000000000') // 10B tokens
    await TestToken.transfer(simUser2.address, '10000000000000000000000000000') // 10B tokens

    // add a track
    mineNext()
    await IFAllocationMaster.addTrack(
      'TEST Track', // name
      TestToken.address, // stake token
      '10000000', // weight accrual rate
      '100000000000000000', // passive rollover rate (10%)
      '200000000000000000', // active rollover rate (20%)
      '10000000000000000000000000000' // max total stake (10B)
    )

    //// block-by-block simulation

    // simulation reference inputs and outputs
    const simIn = simulations[0].in
    const simExpectedOut = simulations[0].out

    // run
    const simOutput = await simAllocationMaster(
      IFAllocationMaster, // staking contract
      TestToken, // stake token
      (await IFAllocationMaster.trackCount()) - 1, // track number
      [simUser1, simUser2], // simulation users
      simIn
    )
    // // write output to CSV
    await asyncWriteFile(
      './test/simulationData',
      '.tmp.out1.csv',
      unparseCsv(simOutput)
    )

    //// check simulation output against output csv
    // get lines of expected output and simulation
    const expectedLines = (await readFile(simExpectedOut)).split(/\r?\n/)
    const simOutLines = unparseCsv(simOutput).split(/\r?\n/)

    // compare each line
    expectedLines.map((expectedLine, i) => {
      expect(expectedLine).to.equal(simOutLines[i])
    })
  })

  it('simulation 2: rollovers', async () => {
    // allocate stake token to simulation user1 and user2
    mineNext()
    await TestToken.transfer(simUser1.address, '10000000000000000000000000000') // 10B tokens
    await TestToken.transfer(simUser2.address, '10000000000000000000000000000') // 10B tokens

    // add a track
    mineNext()
    await IFAllocationMaster.addTrack(
      'TEST Track', // name
      TestToken.address, // stake token
      '10000000', // weight accrual rate
      '100000000000000000', // passive rollover rate (10%)
      '200000000000000000', // active rollover rate (20%)
      '10000000000000000000000000000' // max total stake (10B)
    )

    //// block-by-block simulation

    // simulation reference inputs and outputs
    const simIn = simulations[1].in
    const simExpectedOut = simulations[1].out

    // run
    const simOutput = await simAllocationMaster(
      IFAllocationMaster, // staking contract
      TestToken, // stake token
      (await IFAllocationMaster.trackCount()) - 1, // track number
      [simUser1, simUser2], // simulation users
      simIn
    )

    // // write output to CSV
    await asyncWriteFile(
      './test/simulationData',
      '.tmp.out2.csv',
      unparseCsv(simOutput)
    )

    //// check simulation output against output csv
    // get lines of expected output and simulation
    const expectedLines = (await readFile(simExpectedOut)).split(/\r?\n/)
    const simOutLines = unparseCsv(simOutput).split(/\r?\n/)

    // compare each line
    expectedLines.map((expectedLine, i) => {
      expect(expectedLine).to.equal(simOutLines[i])
    })
  })

  it('simulation 3: disabling track', async () => {
    // allocate stake token to simulation user1 and user2
    mineNext()
    await TestToken.transfer(simUser1.address, '10000000000000000000000000000') // 10B tokens
    await TestToken.transfer(simUser2.address, '10000000000000000000000000000') // 10B tokens

    // add a track
    mineNext()
    await IFAllocationMaster.addTrack(
      'TEST Track', // name
      TestToken.address, // stake token
      '10000000', // weight accrual rate
      '100000000000000000', // passive rollover rate (10%)
      '200000000000000000', // active rollover rate (20%)
      '10000000000000000000000000000' // max total stake (10B)
    )

    //// block-by-block simulation

    // simulation reference inputs and outputs
    const simIn = simulations[2].in
    const simExpectedOut = simulations[2].out

    // run
    const simOutput = await simAllocationMaster(
      IFAllocationMaster, // staking contract
      TestToken, // stake token
      (await IFAllocationMaster.trackCount()) - 1, // track number
      [simUser1, simUser2], // simulation users
      simIn
    )

    // // write output to CSV
    await asyncWriteFile(
      './test/simulationData',
      '.tmp.out3.csv',
      unparseCsv(simOutput)
    )

    //// check simulation output against output csv
    // get lines of expected output and simulation
    const expectedLines = (await readFile(simExpectedOut)).split(/\r?\n/)
    const simOutLines = unparseCsv(simOutput).split(/\r?\n/)

    // compare each line
    expectedLines.map((expectedLine, i) => {
      expect(expectedLine).to.equal(simOutLines[i])
    })
  })

  it('simulation 4: emergency withdraws', async () => {
    // allocate stake token to simulation user1 and user2
    mineNext()
    await TestToken.transfer(simUser1.address, '10000000000000000000000000000') // 10B tokens
    await TestToken.transfer(simUser2.address, '10000000000000000000000000000') // 10B tokens

    // add a track
    mineNext()
    await IFAllocationMaster.addTrack(
      'TEST Track', // name
      TestToken.address, // stake token
      '10000000', // weight accrual rate
      '100000000000000000', // passive rollover rate (10%)
      '200000000000000000', // active rollover rate (20%)
      '10000000000000000000000000000' // max total stake (10B)
    )

    //// block-by-block simulation

    // simulation reference inputs and outputs
    const simIn = simulations[3].in
    const simExpectedOut = simulations[3].out

    // run
    const simOutput = await simAllocationMaster(
      IFAllocationMaster, // staking contract
      TestToken, // stake token
      (await IFAllocationMaster.trackCount()) - 1, // track number
      [simUser1, simUser2], // simulation users
      simIn
    )

    // // write output to CSV
    await asyncWriteFile(
      './test/simulationData',
      '.tmp.out4.csv',
      unparseCsv(simOutput)
    )

    //// check simulation output against output csv
    // get lines of expected output and simulation
    const expectedLines = (await readFile(simExpectedOut)).split(/\r?\n/)
    const simOutLines = unparseCsv(simOutput).split(/\r?\n/)

    // compare each line
    expectedLines.map((expectedLine, i) => {
      expect(expectedLine).to.equal(simOutLines[i])
    })
  })

  it('simulation 5: 5 users stake and check stake weight use getBatchStakeWeightByTrackId', async () => {
    // create 5 users
    const testUser = (await ethers.getSigners())[5]
    const testUser2 = (await ethers.getSigners())[6]
    const testUser3 = (await ethers.getSigners())[7]
    const testUser4 = (await ethers.getSigners())[8]
    const testUser5 = (await ethers.getSigners())[9]

    mineNext()

    const users = [testUser, testUser2, testUser3, testUser4, testUser5]
    const stakeAmounts = [
      '100000000000000000000000000',
      '500000000000000000000000000',
      '500000000000000000000000000',
      '1000000000000000000000000000',
      '1500000000000000000000000000'
    ]

    // transfer token to each user with rate 1 : 5 : 5 : 10 : 15
    await TestToken.transfer(testUser.address, stakeAmounts[0])
    await TestToken.transfer(testUser2.address, stakeAmounts[1])
    await TestToken.transfer(testUser3.address, stakeAmounts[2])
    await TestToken.transfer(testUser4.address, stakeAmounts[3])
    await TestToken.transfer(testUser5.address, stakeAmounts[4])

    mineNext()

    // add a track
    await IFAllocationMaster.addTrack(
      'TEST Track', // name
      TestToken.address, // stake token
      '10000000', // weight accrual rate
      '0', // passive rollover rate (0%)
      '0', // active rollover rate (0%)
      '20000000000000000000000000000' // 20B
    )
    mineNext()

    const trackId = 0

    // stake token
    for (let j = 0; j < stakeAmounts.length; j++) {
      const amount = stakeAmounts[j]
      const user = users[j]

      await TestToken.connect(user).approve(IFAllocationMaster.address, amount)
      mineNext()
    }

    const currBlockNum = await ethers.provider.getBlockNumber()
    const currBlock = await ethers.provider.getBlock(currBlockNum)

    // get user stake weights
    const userStakeWeights =
      await IFAllocationMaster.getBatchStakeWeightByTrackId(
        trackId,
        currBlock.timestamp,
        0, // start
        10 // size
      )

    const expectedRate = [1, 5, 5, 10, 15]

    // validate
    for (let i = 0; i < userStakeWeights.length; i++) {
      expect(parseFloat(userStakeWeights[i].stakeWeight)).to.equal(
        expectedRate[i] * 1000000000000000
      )
    }
  })
})
