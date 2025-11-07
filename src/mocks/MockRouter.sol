contract MockRouter {
    struct MockFillCall {
        address target;
        bytes callData;
    }

    function mockFill(MockFillCall[] calldata mockFills) external {
        for (uint256 i; i < mockFills.length; i++) {
            address target = mockFills[i].target;
            bytes calldata callData = mockFills[i].callData;
            (bool success,) = target.call(callData);
            require(success);
        }
    }
}
