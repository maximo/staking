import signal
from brownie import (
    TransparentUpgradeableProxy,
    ProxyAdmin,
    veSPA_v1,
    veSPA_test,
    Contract,
    chain,
)
import eth_utils

GAS_LIMIT = 10000000


def test_upgrade():
    # contract owner account
    owner = '0xe0C97480CA7BDb33B2CD9810cC7f103188de4383'
    admin = '0x734A695F76570ad2a3ffb4f339D41Ef78B89B463'

    spa = '0x5575552988A3A80504bBaeB1311674fCFd40aD4B'

    # Deploy the proxy admin contract
    proxy_admin = ProxyAdmin.deploy(
        {'from': admin, 'gas': GAS_LIMIT}
    )

    # Deploy the main veSPA contract
    vespa_base = veSPA_v1.deploy(
        {'from': owner, 'gas': GAS_LIMIT}
    )

    vespa_base.initialize(
        spa,
        'v0',
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

    print(f'veSPA contract deployed at: {vespa_proxy.address}')

    # upgrade

    new_vespa_logic = veSPA_test.deploy(
        {'from': owner, 'gas_limit': GAS_LIMIT}
    )

    new_vespa_logic.initialize(
        spa,
        'v1',
        {'from': owner, 'gas': GAS_LIMIT}
    )

    proxy_admin.upgrade(
        vespa.address,
        new_vespa_logic.address,
        {'from': admin, 'gas_limit': GAS_LIMIT}
    )

    assert vespa.totalSupply() == 1
    upgraded_vespa = Contract.from_abi('upgraded_veSPA', vespa_proxy.address, veSPA_test.abi)
    upgraded_vespa.testAssigniing({'from': owner})
    assert upgraded_vespa.appendedTestVariable() == 1

