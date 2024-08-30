import brownie
from brownie import (
    veSPA_v1,
    RewardDistributor_v1,
    MockToken,
    TransparentUpgradeableProxy,
    chain,
    Contract,
    network,
)

GAS_LIMIT = 12000000

address_dict = {
    'arbitrum-main-fork': {
        'spa': '0x5575552988A3A80504bBaeB1311674fCFd40aD4B',
        'owner': '0xc28c6970D8A345988e8335b1C229dEA3c802e0a6',
        'admin': '0x42d2f9f84EeB86574aA4E9FCccfD74066d809600',
        'proxy_admin': '0x06910Bd3eA422e6d6d8EBb4F9Afe8302dC506B65',
        'vespa_logic_contract': '0xD16f5343FDDD2DcF6A8791e302A204c13069D165',
        'vespa_proxy': '0x2e2071180682Ce6C247B1eF93d382D509F5F6A17',
        'vespa': '0x2e2071180682Ce6C247B1eF93d382D509F5F6A17',
        'reward_distributor': '0x2c07bc934974BbF413a4a4CeDA98713DCb8d9e16',
        'whale': '0xb56e5620a79cfe59af7c0fcae95aadbea8ac32a1'
    },
    'mainnet-fork': {
        'spa': '0xB4A3B0Faf0Ab53df58001804DdA5Bfc6a3D59008',
        'owner': '0xc28c6970D8A345988e8335b1C229dEA3c802e0a6',
        'admin': '0x42d2f9f84EeB86574aA4E9FCccfD74066d809600',
        'proxy_admin': '0x7ED4Fded967d163EFef7294c99A84534d61C8f56',
        'vespa_logic_contract': '0xA3F8745548A98ee67545Abcb0Cc8ED3129b8fF8D',
        'vespa_proxy': '0xbF82a3212e13b2d407D10f5107b5C8404dE7F403',
        'vespa': '0xbF82a3212e13b2d407D10f5107b5C8404dE7F403',
        'reward_distributor': '0xa61DD4480BE2582283Afa54E461A1d3643b36040',
        'whale': '0xd6d462c58d09bff7f8ec49a995b38ea89c9c5402'
    }
}


def main():
    user_account = input('Enter your metamask wallet address: ')

    net = network.show_active()
    owner = address_dict[net]['owner']
    spa = brownie.Contract.from_abi(
        'SPA',
        address_dict[net]['spa'],
        MockToken.abi
    )

    vespa_base = Contract.from_abi(  # noqa
        'veSPA_logic',
        address_dict[net]['vespa_logic_contract'],
        veSPA_v1.abi
    )
    vespa_proxy = Contract.from_abi(
        'TransparentUpgradeableProxy',
        address_dict[net]['vespa_proxy'],
        TransparentUpgradeableProxy.abi
    )
    vespa = Contract.from_abi('veSPA', vespa_proxy, veSPA_v1.abi)  # noqa
    rd = Contract.from_abi(
        'RD',
        address_dict[net]['reward_distributor'],
        RewardDistributor_v1.abi
    )

    brownie.accounts[0].transfer(user_account, '50 ether')

    whale = address_dict[net]['whale']
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
