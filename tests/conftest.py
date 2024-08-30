import pytest
import os
import brownie
from dotenv import load_dotenv

from brownie import (
    veSPA_v1,
    MockToken,
    ProxyAdmin,
    accounts,
    TransparentUpgradeableProxy,
    Contract,
)
import eth_utils


MIN_BALANCE = 1000000000000000000
GAS_LIMIT = 10000000

load_dotenv()


@pytest.fixture(scope='module', autouse=True)
def owner():
    if brownie.network.show_active() == 'arbitrum-rinkeby':
        owner = accounts.add(os.getenv('LOCAL_ACCOUNT_PRIVATE_KEY'))
        if(owner.balance() < MIN_BALANCE):
            pytest.exit('Insufficient funds with Owner account!!')
        for _ in range(3):
            accounts.add()
        return owner
    return accounts[0]


@pytest.fixture(scope='module', autouse=True)
def spa(owner):
    if brownie.network.show_active() == 'arbitrum-rinkeby':
        return brownie.Contract.from_abi(
            'spa',
            '0x27259063B77E5907b6a0de042dE5f68f74cd902f',
            MockToken.abi
        )
    token = MockToken.deploy(
        'L2 Sperax Token',
        'SPA',
        int(10 ** 18),
        {'from': owner}
    )
    print('SPA: ', token.address)
    return token


def mint_and_approve(spa, vespa, account):
    spa.mint(100000000000000000000000, {'from': account})
    spa.approve(vespa, int(100000 * 10 ** 18), {'from': account})


@pytest.fixture(scope='module', autouse=True)
def vespa(
    spa,
    owner
):
    # Deploy the proxy admin contract
    proxy_admin = ProxyAdmin.deploy(
        {'from': owner, 'gas': GAS_LIMIT}
    )

    # Deploy the main veSPA contract
    vespa_base = veSPA_v1.deploy(
        {'from': owner, 'gas': GAS_LIMIT}
    )

    # Deploy the proxy contract for the vespa contract
    proxy = TransparentUpgradeableProxy.deploy(
        vespa_base.address,
        proxy_admin.address,
        eth_utils.to_bytes(hexstr='0x'),
        {'from': owner, 'gas': GAS_LIMIT},
    )

    vespa = Contract.from_abi('veSPA', proxy.address, veSPA_v1.abi)
    with brownie.reverts('_SPA is zero address'):
        vespa.initialize(
                         '0x0000000000000000000000000000000000000000',
                         'v0',
                         {'from': owner, 'gas': GAS_LIMIT}
        )
    vespa.initialize(
        spa,
        'v0',
        {'from': owner, 'gas': GAS_LIMIT}
    )
    mint_and_approve(spa, vespa, owner)

    return vespa
