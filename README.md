# ENS Hardware-Controlled Accounts (HCA)

Smart account infrastructure for ENS hardware-backed signers, built on [Nexus](https://github.com/rhinestonewtf/rhinestone-nexus) (ERC-7579 / ERC-4337).

## Architecture

```
┌─────────────┐         deploys          ┌──────────────┐
│ HCAFactory  │ ─────── CREATE3 ───────▶ │ NexusProxy   │
│             │                          │  (per-user)  │
│ setImpl()   │                          │  ──────────  │
│ createAcct()│                          │  delegatecall│
└──────┬──────┘                          └──────┬───────┘
       │ owns reference to                      │
       ▼                                        ▼
┌──────────────┐                         ┌──────────────┐
│ HCA (impl)   │ ◀── delegated calls ──  │              │
│ extends Nexus│                         │              │
│              │                         │              │
│ • locked-down│                         └──────────────┘
│   module cfg │
│ • NFT reject │
│ • upgrade    │
│   guard      │
└──────┬───────┘
       │ immutable refs
       ├──▶ HCAModule (default validator)
       └──▶ IntentExecutor (default executor)
```

### Contracts

#### `HCA` (`src/hca/HCA.sol`)

The account implementation. Extends Nexus with a locked-down security model:

- **Immutable default validator** — set at deploy time via the Nexus `_DEFAULT_VALIDATOR`. All UserOp and EIP-1271 signature validation routes through this module.
- **Immutable default executor** — the Rhinestone IntentExecutor is set as Nexus's `_DEFAULT_EXECUTOR`, giving it `executeFromExecutor` permissions without needing to be installed in the sentinel list.
- **Module locking** — `installModule` and `uninstallModule` always revert. The account's module configuration is fixed at initialization.
- **Upgrade guard** — UUPS upgrades are restricted to the implementation currently registered on the HCAFactory. The factory owner controls which implementation accounts can upgrade to.
- **NFT rejection** — the fallback function reverts on `onERC721Received`, `onERC1155Received`, and `onERC1155BatchReceived`, preventing the account from holding NFTs.

The constructor takes:

| Parameter | Description |
|---|---|
| `hcaFactory_` | The factory managing this account's lifecycle |
| `entryPoint_` | The ERC-4337 EntryPoint |
| `defaultValidator_` | HCAModule address (immutable K1 validator) |
| `intentExecutor_` | IntentExecutor address (immutable default executor) |
| `validatorInitData_` | Template data passed to the validator at construction (blocks direct use of the implementation) |

#### `HCAModule` (`src/hca-module/HCAModule.sol`)

The validator module. Extends `OwnableValidator` with HCA-specific constraints:

- Implements `IHCAInitDataParser` so the factory can extract the primary owner from init data.
- Enforces that the first owner must be permanent (`expiration == type(uint48).max`).
- Multi-sig with configurable k-of-n threshold and time-based owner expiration.

#### `OwnableValidator` (`src/hca-module/base/OwnableValidator.sol`)

The base ERC-7579 validator providing:

- **Multi-signature validation** with configurable threshold (1-of-n to n-of-n).
- **Owner expiration** — each owner has a `uint48` expiration timestamp. Expired owners are automatically excluded from signature validation. `type(uint48).max` means permanent.
- **Dual validation modes** — stateful (stored config) and stateless (config passed in calldata).
- **Owner management** — `updateConfig` for atomic add/remove/threshold changes, `updateOwnerExpiration` for extending/reducing access.
- Owners stored as packed `bytes32` values: `[address 160b][expiration 48b][unused 48b]`.

#### `HCAFactory` (`@ensdomains/contracts-v2`)

The factory that deploys HCA proxies:

- Deploys `NexusProxy` instances via CREATE3, deriving deterministic addresses from the primary owner.
- Delegates to an `IHCAInitDataParser` (the HCAModule) to extract the owner from init data.
- The factory owner can update the implementation via `setImplementation`, which controls what accounts can upgrade to.
- `createAccount` is idempotent — calling it again for the same owner forwards ETH to the existing account.

## Account Lifecycle

1. **Deploy implementation** — `new HCA(factory, entryPoint, hcaModule, intentExecutor, templateInitData)`
2. **Register on factory** — `factory.setImplementation(hcaImpl, hcaModule)`
3. **Create account** — `factory.createAccount(initData)` where `initData = abi.encode(threshold, owners[])`
   - Factory deploys a NexusProxy via CREATE3
   - Proxy calls `HCA.initializeAccount(initData)` which installs the validator with the provided owners and initializes the default executor
4. **Use** — the account validates UserOps through HCAModule, executes intents through the default executor, and rejects any module changes
5. **Upgrade** — factory owner sets a new implementation, then the account (via UserOp) calls `upgradeToAndCall` which only accepts the factory's current implementation

## Development

```shell
pnpm install
forge build
forge test
```

## Dependencies

| Package | Source |
|---|---|
| `@rhinestone/nexus` | `rhinestonewtf/rhinestone-nexus` (branch: `feat/default-executor`) |
| `@ensdomains/contracts-v2` | `zeroknots/ens-contracts-v2` |
| `@rhinestone/modulekit` | `rhinestonewtf/modulekit` |
| `@rhinestone/compact-utils` | local link |

## License

GPL-3.0
