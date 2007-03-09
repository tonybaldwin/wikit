# Wikit startup code, locks and chooses between CGI and Tk mode

package provide app-wikit 0.1
if {[catch { package require Mk4tcl }]} {
  package require mklite
  mklite::emulateMk4tcl
}

set roflag [lsearch -exact $argv "-readonly"]
if {$roflag >= 0} {
  set argv [lreplace $argv $roflag $roflag]
  incr argc -1
}

set uselock 1
set nolock [lsearch -exact $argv "-nolock"]
if {$nolock >= 0} {
  set argv [lreplace $argv $nolock $nolock]
  incr argc -1
  set uselock 0
}
unset nolock

set pos [lsearch -exact $argv "-images"]
if {$pos >= 0} {
  set imflag [lindex $argv [incr pos]]
  set argv [lreplace $argv [expr {$pos-1}] $pos]
  incr argc -2
}
unset pos

set pos [lsearch -exact $argv "-update"]
if {$pos >= 0} {
  set upflag [lindex $argv [incr pos]]
  set argv [lreplace $argv [expr {$pos-1}] $pos]
  incr argc -2
}
unset pos

# the wikit httpd server
set wikit_httpd ""
set pos [lsearch -exact $argv "-httpd"]
if {$pos >= 0} {
  set wikit_httpd [lindex $argv [incr pos]]
  set argv [lreplace $argv [expr {$pos-1}] $pos]
  incr argc -2
  # on Windows we need to display a console (if we can - we might be running
  # under tclkitsh)
  if {$::tcl_platform(platform) eq "windows"} {
    if {![catch {console show}]} {
      # probably tclkit - create a simple button to stop the server
      proc console_hide {} {
        console hide
        .c configure -text "Show wikit httpd server console" -command console_show
      }
      proc console_show {} {
        .c configure -text "Hide wikit httpd server console" -command console_hide
        console show
      }
      button .c
      button .e -text "Exit wikit httpd server" -command exit
      pack .c .e -fill x 
      wm title . "Wikit httpd server"
      console title "Wikit httpd server console"
      console_show
      after idle raise .
    }
  }
}
unset pos

# avoid things like "-help" from becoming a file name
if {[string index $argv 0] eq "-"} {
  error "unknown option: $argv"
}

if {$argc} {
  set wikidb [lindex $argv 0]
} else {
  # this should be derived from the basename of the executable that
  # invokes wikit
  set wikidb wikit.tkd
}

# 2002-12-08: quick intercept of NNN.txt page requests
catch {
  if {$env(REQUEST_METHOD) eq "GET" &&
      [regexp {/(\d+)\.txt$} $env(REQUEST_URI) - page]} {
    mk::file open xdb $wikidb -readonly
    puts "Content-type: text/plain\n"
    puts "Title:\t[mk::get xdb.pages!$page name]"
    puts "Date:\t[clock format [mk::get xdb.pages!$page date] \
    				-gmt 1 -format {%e %b %Y %H:%M:%S GMT}]"
    puts "Site:\t[mk::get xdb.pages!$page who]"
    puts ""
    puts -nonewline [mk::get xdb.pages!$page page]
    exit
  }
}

package require Wikit::Utils

# 2002-06-17: read everything before locking down the database
# this way, if a transfer takes long, it won't hold up other CGI's
# this is essential to avoid hanging on a "Moz 0.9.9 > 8 Kb edit" bug

if {[info exists ::env(SCRIPT_NAME)]} {
  fconfigure stdout -encoding utf-8
  fconfigure stdin -encoding utf-8
  encoding system utf-8
  package require cgi
  cgi_input
}

set appname [file rootname [file tail $wikidb]]

package require Wikit::Lock
if {$uselock && ![Wikit::AcquireLock $appname.lock]} {
  puts stderr "Can't lock: $appname.lock" ;# the laziest way out
  exit 1
}

# make sure the lock is always released
if {$uselock} {
  rename exit Wikit::exit
  proc exit {args} {
    global appname
    file delete $appname.lock
    catch {eval Wikit::exit $args}
    return
  }
}

if {[catch {
  package require Wikit::Format
  namespace import Wikit::Format::*

  package require Wikit::Db

  Wikit::WikiDatabase $wikidb

  if {[mk::view size wdb.pages] == 0} {
    # copy first 10 pages of the default datafile 
    set fd [open [file join $starkit::topdir doc wikidoc.tkd]]
    mk::file load wdb $fd
    close $fd
    mk::view size wdb.pages 10
    mk::view size wdb.archive 0
    Wikit::FixPageRefs
  }

  if {[info exists upflag]} {
    Wikit::DoSync $upflag
  }

  package require Wikit::Cache
  Wikit::BuildTitleCache

  if {[info exists ::env(SCRIPT_NAME)]} {
    package require Web
    eval [mk::get wdb.pages!9 page]
    if {[info exists ::env(WIKIT_ADMIN)]} {
      set ProtectedPages {}
    }
    Wikit::ProcessCGI
  } elseif { $wikit_httpd ne "" } { 
      encoding system utf-8
      package require cgi      
      package require Web
      package require wikithttpd

      #set ::httpd::debug 1
      eval [mk::get wdb.pages!9 page]
      if {[info exists ::env(WIKIT_ADMIN)]} {
	  set ProtectedPages {}
      }
      ::httpd::startServer localhost $wikit_httpd
      vwait forever
  } elseif {[info exists imflag]} {
    package require Wikit::Image
    Wikit::LocalImages $imflag
  } elseif {[catch {package require Wikit::Gui} msg]} {
    if {$uselock} { Wikit::ReleaseLock $appname.lock }
    exit 1
  } else {
    Wikit::LocalInterface 
  }
} err]} {
  puts stderr "error: $errorInfo"
}

if {$uselock} { Wikit::ReleaseLock $appname.lock }
