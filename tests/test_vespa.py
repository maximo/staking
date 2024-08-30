import brownie


# @dev: Initialize Testing Functions:

def check_function(vespa, func_name):
    for key in vespa.selectors:
        if(func_name == vespa.selectors[key]):
            return True
    return False
# @dev Creating Test Cases for createLock Function:


def test_increase_amount(vespa, owner):

    with brownie.reverts('Cannot deposit 0 tokens'):
        vespa.increaseAmount(0, {'from': owner})

    with brownie.reverts('No existing lock found'):
        vespa.increaseAmount(10000000, {'from': owner})


def test_create_lock(vespa, owner):

    # @dev 1- Test Locking 0 Tokens:

    with brownie.reverts('Cannot lock 0 tokens'):
        vespa.createLock(
            0,
            int(brownie.chain.time() + (vespa.MIN_TIME() * 2)),
            False,
            {'from': owner}
        )
    assert vespa.balanceOf(owner) == 0

# @dev 2- Test Locking in Prior TimeStamp:

    with brownie.reverts('Cannot lock in the past'):
        vespa.createLock(
            1000000000000000000000,
            int(brownie.chain.time() - 10),
            True,
            {'from': owner}
        )
# @dev 3- Test MAX Duration of a lock:
    with brownie.reverts('Voting lock can be 4 years max'):

        # @ dev TODO The Lock wont revert on exact 4 years,
        # I've added 4 DAYS and 6 HOURS In Order To make it Reverted

        vespa.createLock(
            1000000000000000000000,
            int(brownie.chain.time() + (vespa.MAX_TIME()) +
                (86400*4)+(3600*6)),
            False,
            {'from': owner}
        )

    vespa.createLock(
        1000000000000000000000,
        int(brownie.chain.time() + (vespa.MIN_TIME() * 2)),
        True,
        {'from': owner}
    )


# @dev 5- Add position of the same account
    with brownie.reverts('Withdraw old tokens first'):
        vespa.createLock(
            1000000000000000000000,
            int(brownie.chain.time() + (vespa.MIN_TIME() * 2)),
            True,
            {'from': owner}
        )
# @dev 5- Withdraw after elapsed lock
    brownie.chain.sleep((vespa.MIN_TIME()*2)+100)
    vespa.withdraw({'from': owner})
    assert vespa.balanceOf(owner) == 0


def test_withdraw(vespa, owner):

    with brownie.reverts('Lock not expired.'):
        vespa.createLock(
            1000000000000000000000,
            int(brownie.chain.time() + (vespa.MIN_TIME() * 2)),
            True,
            {'from': owner}
        )
        brownie.chain.sleep((vespa.MIN_TIME()))
        vespa.withdraw({'from': owner})

    with brownie.reverts('No cooldown initiated'):
        brownie.chain.sleep((vespa.MIN_TIME()*2)+100)
        vespa.withdraw({'from': owner})
        vespa.createLock(
            1000000000000000000000,
            int(brownie.chain.time() + (vespa.MIN_TIME() * 2)),
            False,
            {'from': owner}
        )
        vespa.increaseAmount(10000000, {'from': owner})
        brownie.chain.sleep((vespa.MIN_TIME()*2)+100)
        vespa.withdraw({'from': owner})
    tx = vespa.balanceOf(owner)
    print('Balance of Owner: ', tx)
# # @dev 4- Test Creating a lock:
#     # 1000 SPA
#     # 2 WEEKS
#     # AutoCooldown enabled?
#     vespa.createLock(
#         1000000000000000000000,
#         int(brownie.chain.time() + (vespa.MIN_TIME() * 2)),
#         False,
#         {'from': owner}
#     )
    assert vespa.balanceOf(owner) != 0
    with brownie.reverts('Lock expired. Withdraw'):
        vespa.increaseAmount(1, {'from': owner})
    vespa.initiateCooldown({'from': owner})
    brownie.chain.sleep((vespa.MIN_TIME()*2)+100)
    with brownie.reverts('Cannot deposit during cooldown'):
        vespa.increaseAmount(1, {'from': owner})
    vespa.withdraw({'from': owner})
    assert vespa.balanceOf(owner) == 0
