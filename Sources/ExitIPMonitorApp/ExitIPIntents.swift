import AppIntents

enum ExitIPDestination: String, AppEnum {
    case dashboard

    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Exit IP screen")
    static let caseDisplayRepresentations: [ExitIPDestination: DisplayRepresentation] = [
        .dashboard: DisplayRepresentation(title: "Dashboard")
    ]
}

/// Add this file to both the app target and the widget-extension target.
/// `OpenIntent` brings the app to the foreground when the Control Center button is used.
struct OpenExitIPDashboardIntent: OpenIntent {
    static let title: LocalizedStringResource = "Open Exit IP"

    @Parameter(title: "Destination", default: .dashboard)
    var target: ExitIPDestination

    /// App Intents needs a parameterless initializer to deserialize the intent.
    init() {}

    /// The explicit wrapped-value initializer prevents Swift from selecting the
    /// property-wrapper (`IntentParameter`) initializer at a ControlWidget call site.
    init(target: ExitIPDestination) {
        self.target = target
    }
}
