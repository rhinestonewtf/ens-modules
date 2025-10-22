import {
    CompactEnvironment,
    ModuleKitHelpers,
    TestHelperLib,
    Element,
    Mandate
} from "@rhinestone/compact-utils/src/tests/Environment.sol";

contract BaseTest is CompactEnvironment {
    using ModuleKitHelpers for *;

    function setUp() public virtual {
        _deployCompact();
        _deploySmartAccount({ create: true });
        _setEmissary(env.smartAccount1, env.eoa);
        _lockAssets(env.smartAccount1, env.token1, 100 ether);
    }
}
