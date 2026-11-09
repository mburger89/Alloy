import AlloyCore
import Testing

@Test func alloyCoreNamespaceExists() {
    #expect(String(describing: AlloyCore.self) == "AlloyCore")
}
