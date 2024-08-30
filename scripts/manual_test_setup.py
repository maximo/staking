from brownie import (
    veSPA_v1,
    RewardDistributor_v1,
    MockToken,
    ProxyAdmin,
    TransparentUpgradeableProxy,
    accounts,
    chain,
    Contract,
)

import eth_utils

# --- Commands to help with the test ---
# To start: brownie run ./scripts/manual_test_setup.py
#   --network arbitrum-main-fork -I -t
# vespa.balanceOf(owner)
# vespa.totalSupply()
# chain.snapshot() => Save the current state of the chain
# chain.revert() => To revert to the previous snapshot of the chain
# chain.mine(10, newTimestamp)
#   => To mine 10 blocks with a new timestamp,
# chain.mine(10, vespa.lockedEnd(owner))
#   => To jump to the end time of the lock.
# vespa.initializeCooldown() => To initialize the cooldown of the lock.
# vespa.withdraw() => To withdraw the SPA from the lock.
# exit() => To exit the program.

GAS_LIMIT = 200000000


def mint_and_approve(spa, desiredAddress, account, mint=False):
    if(mint):
        spa.mint(100000000000000000000000, {'from': account})
    spa.approve(desiredAddress, int(100000 * 10 ** 18), {'from': account})


def main():
    owner = accounts[0]
    admin = owner

    print(f'contract owner account: {owner.address}\n')

    spa = MockToken.deploy(
        'L2 Sperax Token',
        'SPA',
        int(10 ** 18),
        {'from': owner}
    )

    # Deploy the proxy admin contract
    proxy_admin = ProxyAdmin.deploy(
        {'from': admin, 'gas': GAS_LIMIT}
    )

    # Deploy the main veSPA contract
    vespa_base = veSPA_v1.deploy(
        {'from': owner, 'gas': GAS_LIMIT}
    )

    # Deploy the proxy contract for the vespa contract
    vespa_proxy = TransparentUpgradeableProxy.deploy(
        vespa_base.address,
        proxy_admin.address,
        eth_utils.to_bytes(hexstr='0x'),
        {'from': admin, 'gas': GAS_LIMIT},
    )

    vespa = Contract.from_abi('veSPA', vespa_proxy.address, veSPA_v1.abi)

    vespa.initialize(
        spa,
        'v0',
        {'from': owner, 'gas': GAS_LIMIT}
    )

    mint_and_approve(spa, vespa, owner)
    mint_and_approve(spa, vespa, accounts[1], True)

    # 1000 SPA
    # 2 WEEKS
    # AutoCooldown enabled?
    vespa.createLock(
        1000000000000000000000,
        int(chain.time() + (vespa.MAX_TIME())),
        False,
        {'from': owner}
    )

    # 1000 SPA
    # 2 WEEKS
    # AutoCooldown enabled?
    vespa.createLock(
        1000000000000000000000,
        int(chain.time() + (vespa.MAX_TIME())),
        False,
        {'from': accounts[1]}
    )

    rd = RewardDistributor_v1.deploy(
        spa,
        vespa,
        chain.time() + 604800,
        {'from': owner, 'gas': GAS_LIMIT}
    )

    mint_and_approve(spa, rd, owner)

    chain.snapshot()
    week = []
    week.append(rd.startTime())
    for i in range(4):
        week.append(week[-1] + rd.WEEK())

    # week 0
    # # Add rewards for week 1
    chain.mine(10, week[0])

    # # Checkpoint the rewards
    rd.toggleAllowCheckpointReward({'from': owner})
    rd.addRewards(10000000000000000000, {'from': owner})
    # Users can't get rewards for the ongoing week.
    # Week 1
    chain.mine(10, week[1])
    # Claim the rewards for the user
    print(rd.computeRewards(owner))
    t1 = rd.claim(owner, True, {'from': owner})
    print(t1.events)

    # Week 2
    chain.mine(10, week[3])

    # Add rewards for week 2
    t2 = rd.addRewards(20000000000000000000, {'from': owner})
    print(t2.events)
