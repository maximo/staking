import brownie
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

GAS_LIMIT = 12000000

L2_SPA_addr = '0x5575552988A3A80504bBaeB1311674fCFd40aD4B'


def main():
    owner = accounts[0]
    admin = accounts[1]
    user_account = input('Enter your metamask wallet address: ')

    print(f'contract owner account: {owner.address}\n')

    spa = brownie.Contract.from_abi('L2_SPA', L2_SPA_addr, MockToken.abi)

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

    rd = RewardDistributor_v1.deploy(
        spa,
        vespa,
        chain.time() + 604800,  # Reward distribution starts after a week
        {'from': owner, 'gas': GAS_LIMIT}
    )

    print(f'Reward Distributor deployed at: {rd.address}')

    brownie.accounts[0].transfer(user_account, '50 ether')

    whale = '0xb56e5620a79cfe59af7c0fcae95aadbea8ac32a1'
    print(f'SPA balance of user before transfer: {spa.balanceOf(user_account)}\n') # noqa
    print(f'SPA balance of whale before transfer: {spa.balanceOf(whale)}\n')
    spa.transfer(user_account, 100000000000000000000000000, {'from': whale})
    spa.transfer(owner, 100000000000000000000000000, {'from': whale})
    spa.approve(rd, 100000000000000000000000000, {'from': owner})
    print(f'SPA balance of user after transfer: {spa.balanceOf(user_account)}\n') # noqa
    print(f'SPA balance of owner after transfer: {spa.balanceOf(owner)}\n') # noqa
    print(f'SPA balance of whale after transfer: {spa.balanceOf(whale)}\n')

    chain.snapshot()
    week = []
    week.append(rd.startTime())
    for i in range(4):
        week.append(week[-1] + rd.WEEK())
