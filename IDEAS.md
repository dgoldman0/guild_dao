1. Might really be good to break the contract up. And there was always the idea of taking this approach and them mapping it onto the AragonOS paradigm to integrate into their existing infrastructure. Probably would be good to have the actual rank information be in one contract and have it controlled by a separate contract that has the governance infrastructure.

2. Membership fees. Active/inactive membership (turns on/of voting power and will require adjustment in both contracts) based on whether fees are paid (higher rank requires higher fees) might be interesting and also acts as a nice token sink for a DAO's economic token if it has its own, or a shared token commonly used for fees. Probably tied to 100 day epochs.

3. Splice out rank system or if possible within single contract size limitation allow adjustment for rank parameters such as how many invites, vote multiplier, etc. 

4. Add setting to TreasuryDAO that determines whether the DAO is general or rank specific (if rank specific do flat voting and only allow members of that rank to vote or maybe greater than or equal to and multiplier voting, not sure).

5. Add explicit voting to allow changing the assigned ranked DAO that controls the treasury. Cannot be changed as of now because it's set to immutable. Removing that keyword would allow a global call vote. 