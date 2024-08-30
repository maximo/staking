import signal
from brownie import (
    TransparentUpgradeableProxy,
    ProxyAdmin,
    RewardDistributor,
    veSPA_v1,
    Contract,
    chain,
)
import eth_utils
from .utils import (
    get_account,
    save_deployment_artifacts,
    getConstantsFromNetwork,
    signal_handler,
)

from .constants import (
    mainnet_addresses,
    testnet_addresses,
)

GAS_LIMIT = 190000000


def main():
    # handle ctrl-C event
    signal.signal(signal.SIGINT, signal_handler)

    # contract owner account
    owner = get_account('owner account')
    admin = get_account('admin account')

    spa = getConstantsFromNetwork(
        testnet_addresses.L2_SPA,
        mainnet_addresses.L2_SPA
    )

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

    print(f'veSPA proxy contract deployed at: {vespa_proxy.address}')
    print(f'veSPA implementation contract deployed at: {vespa_base.address}')

    reward_distributor = RewardDistributor.deploy(
        spa,
        vespa,
        chain.time(),
        {'from': owner, 'gas': GAS_LIMIT}
    )

    print(f'reward_distributor contract deployed at: {reward_distributor.address}')

    # Create a dict with all the relevant data to be persisted
    data = dict(
        type='deployment',
        spa=spa,
        vespa_logic_contract=vespa_base.address,
        vespa_proxy=vespa_proxy.address,
        reward_distributor=reward_distributor.address,
        proxy_admin=proxy_admin.address,
        owner=owner.address,
    )

    save_deployment_artifacts(data)
