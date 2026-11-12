import ArgumentParser

@main
struct AlloyBench: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "alloy-bench",
        abstract: "Benchmark Zed, Delta and Alloy with identical scenarios.",
        subcommands: [RunCommand.self, PublishCommand.self, SiteCommand.self, HotspotsCommand.self],
        defaultSubcommand: RunCommand.self)
}
