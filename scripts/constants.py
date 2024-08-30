class Constants:
    def __init__(self, L2_SPA):
        self.L2_SPA = L2_SPA


testnet_addresses = Constants(
    # for now, the minter is the same as the reward address
    L2_SPA='0x27259063B77E5907b6a0de042dE5f68f74cd902f',
)

mainnet_addresses = Constants(
    # TODO: add mainnet addresses, these are all gibberish
    L2_SPA='0x5575552988A3A80504bBaeB1311674fCFd40aD4B',
)
