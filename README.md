## Foundry

**Foundry is a blazing fast, portable and modular toolkit for Ethereum application development written in Rust.**

Foundry consists of:

- **Forge**: Ethereum testing framework (like Truffle, Hardhat and DappTools).
- **Cast**: Swiss army knife for interacting with EVM smart contracts, sending transactions and getting chain data.
- **Anvil**: Local Ethereum node, akin to Ganache, Hardhat Network.
- **Chisel**: Fast, utilitarian, and verbose solidity REPL.

## Documentation

https://book.getfoundry.sh/

## Usage

### Build

```shell
$ forge build
```

### Test

Unit tests (`test/unit/`) are pure Solidity — math, registry, and swap-executor behavior
against local mocks. No network access, safe to run anytime:

```shell
$ forge test --match-path 'test/unit/*'
```

Fork tests (`test/fork/`) exercise the leverage engine's actual flashloan mechanics against
real, deployed Morpho Blue / Bundler3 / GeneralAdapter1 contracts on Arbitrum — only the
swap venue is mocked. They require an **archive-capable** RPC endpoint in `ARBITRUM_RPC_URL`
(see `.env.example`); the public `arb1.arbitrum.io` endpoint only retains ~30 minutes of
state and cannot serve the pinned block these tests fork from. They fail loudly (not
silently skip) if `ARBITRUM_RPC_URL` is unset:

```shell
$ cp .env.example .env   # fill in an archive RPC URL (Alchemy/Infura/QuickNode)
$ forge test --match-path 'test/fork/*'
```

Full suite:

```shell
$ forge test
```

### Format

```shell
$ forge fmt
```

### Gas Snapshots

```shell
$ forge snapshot
```

### Anvil

```shell
$ anvil
```

### Deploy

```shell
$ forge script script/Counter.s.sol:CounterScript --rpc-url <your_rpc_url> --private-key <your_private_key>
```

### Cast

```shell
$ cast <subcommand>
```

### Help

```shell
$ forge --help
$ anvil --help
$ cast --help
```
