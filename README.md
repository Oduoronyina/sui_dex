# DEX Project

## Overview
This project is a decentralized exchange (DEX) implemented in the Move programming language. It uses the deepbook and custodian modules for managing order books and account capabilities respectively. The DEX supports trading between ETH and USDC.

## Constants
- `CLIENT_ID`: This is a unique identifier for the client. The current value is 122227.
- `MAX_U64`: This is the maximum value that can be held by a variable of type u64.
- `NO_RESTRICTION`: This constant is used to indicate that there are no restrictions on limit orders.
- `FLOAT_SCALING`: This constant is used for scaling float values. The current scaling factor is 1e9.
- `EAlreadyMintedThisEpoch`: This constant is used to indicate that the DEX coin has already been minted in the current epoch.

## Structures
- `DEX`: This is a one-time witness structure used to create the DEX coin.

## Dependencies
This project depends on the deepbook and custodian modules for order book management and account capabilities respectively. It also uses the ETH and USDC modules for handling ETH and USDC assets.

## Getting Started
To get started with this project, clone the repository and navigate to the project directory. Then, compile the Move source files and deploy the compiled bytecode to your local Move VM.

## Contributing
We welcome contributions to this project. Please feel free to submit a pull request or open an issue on GitHub.
