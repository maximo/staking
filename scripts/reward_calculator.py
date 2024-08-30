from brownie import (
    network,
    veSPA_v1,
    chain,
    Contract
)
from .utils import confirm
import json


# Dictionary of concerned conteract addresses
# Key is the network name, value is the veSPA address for that network
vespa_address_dict = {
    'arbitrum-one': '0x2e2071180682Ce6C247B1eF93d382D509F5F6A17',
    'mainnet': '0xbF82a3212e13b2d407D10f5107b5C8404dE7F403',
}


def get_week_epoch(vespa, time, epoch):
    min_epoch = 0
    max_epoch = epoch
    for i in range(0, 128):
        if (min_epoch >= max_epoch):
            break
        mid = (min_epoch + max_epoch + 1) / 2
        if (vespa.pointHistory(mid)[3] <= time):
            min_epoch = mid
        else:
            max_epoch = mid - 1
    return min_epoch


# Function to get veSPA balance for a given network and week timestamp
def get_vespa_balance(network_name, time):
    print('Getting veSPA balance for', network_name)
    network.disconnect()
    network.connect(network_name)
    vespa = Contract.from_abi(
        'veSPA',
        vespa_address_dict[network_name],
        veSPA_v1.abi
    )
    epoch = get_week_epoch(vespa, time, vespa.epoch())
    slope = vespa.pointHistory(epoch)[1]
    spa_locked = slope * 365 * 86400
    return spa_locked, vespa.totalSupply(time)


def distribute_rewards(network_name, rewards, owner):
    print('Adding rewards in network', network_name)
    network.disconnect()
    network.connect(network_name)
    rd = Contract.from_abi(
        'RewardDistributor',
        vespa_address_dict[network_name]['reward_distributor'],
        veSPA_v1.abi
    )
    rd.addRewards(rewards, {'from': owner})


def main():
    print('Confirm the addresses are correct: \n')
    confirm(json.dumps(vespa_address_dict, indent=4) + '\n')
    confirm('NOTE: Please confirm that your infura key is set in the network-config.yaml file') # noqa
    rewards = int(
        float(
            input(
                'Enter the rewards you want to distribute: '
            )
        ) * 10 ** 18
    )
    time = int(
        input(
            'Enter the week timestamp or 0 for current week: '
            )
        )

    # If time is 0, then we calculate the rewards for this week
    if time <= 0:
        time = (chain.time() // 604800) * 604800
    chain_data = {}
    total_vespa = 0
    total_spa = 0
    # Calculate the total veSPA balance across all networks
    for key in vespa_address_dict:
        chain_data[key] = {'vespa': 0, 'rewards': 0, 'spa_locked': 0}
        (spa, vespa) = get_vespa_balance(key, time)
        chain_data[key]['vespa'] = vespa
        chain_data[key]['spa_locked'] = spa
        total_vespa += chain_data[key]['vespa']
        total_spa += chain_data[key]['spa_locked']

    # Calculate the rewards for each network
    for key in vespa_address_dict:
        chain_data[key]['rewards'] = (
            chain_data[key]['vespa'] *
            rewards
        ) // total_vespa

    print('Week timestamp: ', time)
    print('total rewards: ', rewards)
    print('total spa locked across chains', total_spa)
    print('total veSPA across chains', total_vespa)
    print('reward distribution: ', json.dumps(chain_data, indent=4))
