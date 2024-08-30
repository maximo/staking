import signal
import click
import brownie

def main():
    # TO-DO: add veSPA proxy address
    veSPA_proxy_address = 
    # load admin account
    admin = accounts.load(
        click.prompt(
            "admin account",
            type=click.Choice(accounts.load())
        )
    )
    print(f"admin account: {admin.address}\n")

    # load contract owner account
    owner = accounts.load(
        click.prompt(
            "owner account",
            type=click.Choice(accounts.load())
        )
    )
    print(f"contract owner account: {owner.address}\n")

    # proxy admin contract
    # TO-DO: update ProxyAdmin address
    proxy_admin = brownie.Contract.from_abi('ProxyAdmin', '0x3E49925A79CbFb68BAa5bc9DFb4f7D955D1ddF25', ProxyAdmin.abi)
    print(f"\nproxy_admin address: {proxy_admin.address}\n")

    # show network
    print(f"\n{network.show_active()}:\n")

    veSPA_proxy = Contract.from_abi(
        "veSPA",
        veSPA_proxy_address,
        veSPA_v1.abi
    )

    new_vespa_logic = veSPA_v1.deploy(
        {'from': owner, 'gas_limit': 1500000000}
    )

    proxy_admin.upgrade(
        veSPA_proxy_address,
        new_vespa_logic.address,
        {'from': admin, 'gas_limit': 1500000000}
    )

    print(f"original veSPA proxy address: {veSPA_proxy_address.address}")
    print(f"upgraded veSPA implementation address: {new_vespa_logic.address}")

   