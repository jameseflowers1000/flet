library flet_einput;

export "src/extension.dart" show Extension;
// Re-exported so other extensions (notably flet-eslider) can dispatch
// the same command vocabulary without depending on internal `src/` paths.
export "src/input_command_executor.dart"
    show InputCommandExecutor, InputCommandTarget;
