package require starkit
switch -- [starkit::startup] {
    tclhttpd - sourced { }
    default { package require app-wikit }
}
