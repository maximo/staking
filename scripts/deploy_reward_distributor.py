import signal
from brownie import (
    RewardDistributor_v1,
    veSPA_v1,
    Contract,
    chain,
    network,
)
from .utils import (
    confirm,
    get_account,
    save_deployment_artifacts,
    getConstantsFromNetwork,
    signal_handler,
)

from .constants import (
    mainnet_addresses,
    testnet_addresses,
)

import json

GAS_LIMIT = 200000000

vespa_address_dict = {
    'arbitrum-one': '0x2e2071180682Ce6C247B1eF93d382D509F5F6A17',
    'mainnet': '0xbF82a3212e13b2d407D10f5107b5C8404dE7F403',
}


def main():
    # handle ctrl-C event
    signal.signal(signal.SIGINT, signal_handler)
    confirm(
        'EMERGENCY_RETURN address has been updated with the required value?'
        )
    print('Confirm the addresses are correct: \n')
    confirm(json.dumps(vespa_address_dict, indent=4) + '\n')
    assert (network.show_active() in vespa_address_dict.keys)

    # contract owner account
    owner = get_account('owner account')

    spa = getConstantsFromNetwork(
        testnet_addresses.L2_SPA,
        mainnet_addresses.L2_SPA
    )

    vespa = Contract.from_abi(
        'veSPA',
        vespa_address_dict[network.show_active()],
        veSPA_v1.abi
        )

    reward_distributor = RewardDistributor_v1.deploy(
        spa,
        vespa,
        chain.time(),
        {'from': owner, 'gas': GAS_LIMIT}
    )

    # Create a dict with all the relevant data to be persisted
    data = dict(
        type='deployment_reward_distributor',
        spa=spa,
        vespa=vespa.address,
        reward_distributor=reward_distributor.address,
        owner=owner.address,
    )

    save_deployment_artifacts(data)
