import FroggySRECore

if CommandLine.arguments.contains("--daemon") {
    let daemon = SREDaemon()
    await daemon.run()
} else {
    let server = MCPServer()
    await server.run()
}
