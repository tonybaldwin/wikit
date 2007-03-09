#WikitHttpd
#
# An exceedingly tiny HTTP server for Wikit.

package require http 2.3

namespace eval httpd {
    variable version 0.1

    variable debug 0

    #server state array   
    variable server 
    #server($channel) : 1 or does not exists
    #server($channel.head): list of header lines
    #server($channel.data): data received on channel (body)
 
    variable documentRoot [file join [pwd] www]
    variable serverName 
    variable serverAddr
    variable serverPort
    variable serverAdmin "root@localhost"
    variable serverSoftware "WikitHttpd $version (tcl\[kit\] $::tcl_patchLevel)"

    variable cgiOutput

    proc acceptConnection { channel peerIP peerName } {
	variable server

	#configure non-blocking, auto translation, default encoding
	fconfigure $channel -blocking 0 -translation auto -encoding utf-8
	
	#the channel is now ready for reading of the http-header,
	#this should contain the encoding name (if any) that we'll set 
	#later when we've finished reading the head.

	set server($channel.head) [list]
	set server($channel.data) ""
	set server($channel.contentLength) -1
	set server($channel.position) head
	
	fileevent $channel readable [list [namespace current]::readChannelData $channel]
	#this is supposed to be a simple server, so we'll ignore the 
	#'best practice' of only writing to a file on [fileevent writable]

	#all other processing occurs asynchronously, depending on method 
	#GET or POST and is initiated by readChannelData.
	#first the 'head' of the request is read using [gets], until a single
	#empty line is returned. At that point, the header is dispatched to 
	#the header processor and the channel mode changed binary (for POST 
	#data)

	#log client "connection from $peerIP"
    }

    proc readChannelData { channel } {
	variable server
	
	switch $server($channel.position) {
	    head {
		set line [gets $channel]
		if { $line eq "" && ![fblocked $channel] } {
		    processRequest $channel
		    return
		}		
		lappend server($channel.head) $line	
	    }
	    data {
		append server($channel.data) [read $channel]
		if { $server($channel.contentLength) > -1 } {
		    if {[string length $server($channel.data)] >= \
			    $server($channel.contentLength) } {
			processRequestData $channel
		    }
		} else {
		    httpReturn $channel 501 text/plain "501 Unknown content length"
                    close $channel
                    cleanupChannel $channel
		    #seeing as we don't know how many bytes to expect 
		    #we must, alas, process every time...
		    #note that this code is untested...
		    ##processRequestData $channel
		}
	    }
	}
    }

    proc processRequest { channel } {
	variable server

	#parse the request "GET / HTTP/1.0" (first line)
	if { ![regexp -nocase {^([^ ]+) (.+) (HTTP/1..)$} [lindex $server($channel.head) 0] -> method uri protocol] } {
	    httpReturn $channel 400 text/plain "Malformed Request Error\n[lindex $server($channel.head) 0]"
	    close $channel
	    cleanupChannel $channel
	}	
	if { [string first ? $uri] > -1 } {
	    set server($channel.queryString) [string range $uri [expr [string first ? $uri]+1] end]
	} else {
	    set server($channel.queryString) ""
	}
	set server($channel.method) [string toupper $method]
	set server($channel.uri) $uri
	
	foreach head [lrange $server($channel.head) 1 end] {
	    if { [regexp {^([^:]+): (.+)$} $head -> key value] } {
		set server($channel.ch.[string tolower $key]) $value
	    }
	}
	
	if { [info exists server($channel.ch.content-length)] && \
		 [string is integer $server($channel.ch.content-length)]} {
	    set server($channel.contentLength) $server($channel.ch.content-length)
	}

	log  "\[[lindex [fconfigure $channel -peername] 0]\]" "$method $uri"

	switch $method {
	    
	    "GET" {
		runWikit $channel
	    }
	    "POST" {
                set server($channel.position) data
            }
	    default {
		httpReturn $channel 501 text/plain "501 Method not supported\nSorry wikit-httpd only supports GET"
		close $channel
		cleanupChannel $channel
	    }
	}
    }

    proc processRequestData { channel } {
	variable server

	runWikit $channel

    }

    proc runWikit { channel } {
	variable server
	variable cgiOutput

	set cgiOutput ""

	#capture the _cgi state array
	set cgiState [array get ::_cgi]
	startCGI $channel

	namespace eval global {
	    cgi_input
	    Wikit::ProcessCGI
	}
	endCGI

	#restore the _cgi state
	array unset ::_cgi 
	array set ::_cgi $cgiState
	#and _cgi_link didn't exist before either.
	array unset ::_cgi_link
	array unset ::_cgi_uservar

	set pos [string first "\r\n\r\n" $cgiOutput]
	if { $pos > -1 } {
	    set contentType [string range $cgiOutput 0 [expr $pos -1]]
	    set html [string range $cgiOutput [expr $pos +4] end]
	} else {
	    set contentType ""
	    set html $cgiOutput
	    
	}

	httpReturn $channel 200 text/html $html

	close $channel
	cleanupChannel $channel
      
    }

    proc startCGI { channel } {
	variable debug
	variable server
	variable documentRoot
	variable serverAddr
	variable serverName
	variable serverAdmin
	variable serverPort
	variable serverSoftware

	#setup all environment variables needed for CGI
	#and create interp-aliases for puts, gets, read.

	set ::env(GATEWAY_INTERFACE) "CGI/1.1"
	set ::env(DOCUMENT_ROOT) $documentRoot
	
	set startpos [string length $channel.ch.] 
	foreach key [array names server -glob $channel.ch.*] {
	    set name [string toupper [string range $key $startpos end]]
	    regsub -all -- {-} $name {_} name
	    regsub -all { } $name {_} name
	    set ::env(HTTP_$name) $server($key)
	}
	if { $debug } {
	    set ::env(DEBUG) "1"
	}
	set ::env(LOGONSERVER) "wikit"
	set ::env(QUERY_STRING) $server($channel.queryString)
	set ::env(REMOTE_ADDR) [lindex [fconfigure $channel -peername] 0]
	set ::env(REMOTE_PORT) [lindex [fconfigure $channel -peername] 2]
	set ::env(REQUEST_METHOD) $server($channel.method)
	set ::env(REQUEST_URI) $server($channel.uri)
	set ::env(SCRIPT_FILENAME) "/wikit"
	set ::env(SCRIPT_NAME) "/"
	set ::env(SERVER_ADDR) $serverAddr
	set ::env(SERVER_NAME) $serverName
	set ::env(SERVER_ADMIN) $serverAdmin
	set ::env(SERVER_PORT) $serverPort
	set ::env(SERVER_PROTOCOL) "HTTP/1.0"
	set ::env(SERVER_SOFTWARE) $serverSoftware
	set ::env(PATH_INFO) $server($channel.uri)
	set ::env(PATH_TRANSLATED) [file join $documentRoot $server($channel.uri)]
	if { $server($channel.contentLength) != -1 } {
            set ::env(CONTENT_LENGTH) $server($channel.contentLength)
	    set server(cgidata) [string range $server($channel.data) \
	    		0 [expr {$server($channel.contentLength) - 1}]]
        } else {
	    set server(cgidata) $server($channel.data)
	}
	
	rename ::puts ::real_puts
	rename ::httpd::capture_puts ::puts

	rename ::read ::real_read
	rename ::httpd::cgi_fake_read ::read

	set server(puts) ::real_puts

    }

    proc endCGI { } {
	variable server 
	rename ::puts ::httpd::capture_puts 
	rename ::real_puts ::puts

	rename ::read ::httpd::cgi_fake_read 
	rename ::real_read ::read

	set server(puts) puts

    }

    proc httpReturn { channel code type data } {
	variable serverSoftware
	
	switch -glob $code {
	    2* { set status OK }
	    404 { set status "Document Not Found" }
	    4* { set status "Client request error" }
	    500 { set status "Internal Server Error" }
	    501 { set status "Method Not Supported" }
	    5* { set status "Server Error" }
	    default { set status "UNKNOWN_STATUS" }
	}

	# FIXME: If we want to make the encoding configurable, we will
	# also need to convert the data "manually", using [encoding
	# convertto], use [string length] for the Content-length, and
	# [fconfigure -encoding binary] for the channel.

	puts $channel "HTTP/1.0 $code $status"
	puts $channel "Server: $serverSoftware"
	puts $channel "Date: [httpTime]"
	puts $channel "Expires: [httpTime]"
	puts $channel "Connection: close"	
	puts $channel "Accept-Ranges: bytes"	
	puts $channel "Content-Type: $type; charset=utf-8"	
	puts $channel "Content-Length: [string bytelength $data]"
	puts $channel ""

	fconfigure $channel -translation "auto binary" -encoding utf-8
	puts -nonewline $channel $data
    }
    
    proc httpTime { {when ""} } {
        if { $when eq "" } {
	    set when [clock seconds]
	}
	return [clock format $when -format "%a, %d %b %Y %T GMT" -gmt 1]
    }

    proc cleanupChannel { channel } {
	variable server
	catch { unset server($channel) }
	
	foreach element [array names server -glob "$channel.*"] {
	    unset server($element) 
	}
    }

    proc startServer { servername port {admin ""} {ip ""} } {
	variable server
	variable serverName
	variable serverPort
	variable serverAddr
	variable serverAdmin

	#starts the listen socket for the httpd
	if { [info exists server(server)] } {
	    error "Already listening on port $port!"	    
	}
	set server(server) [socket -server [namespace current]::acceptConnection $port]

	#what is the 'log' puts command?
	set server(puts) puts

	set serverName $servername
	set serverPort $port
	if { $admin ne "" } {
	    set serverAdmin $admin
	}
	if { $ip ne "" } {
	    set serverAddr $ip
	} else {
	    set serverAddr [lindex [fconfigure $server(server) -sockname] 0]
	}
	log notice "Now listening: [fconfigure $server(server) -sockname]"
    }

    proc log { type text } {
	variable debug
	variable server	 	   
	$server(puts) "[httpTime]: $type $text"
    }
    



    proc cgi_fake_read { args } {
	#this is rather simpler than puts.
	#[read] is only used with either two or three 
	#arguments, reading stdin: [read stdin length]
	#or some other fd: [read fd]

	if { [llength $args] == 2 && [lindex $args 0] == "stdin" } {
	    return $::httpd::server(cgidata)
	} else {
	    eval real_read $args
	}
    }

    proc capture_puts { args } {
	#this captures cgi output (channel stdout or none)

	#::real_puts ">>$args<<"

	set nonewline 0
	if { [lindex $args 0] eq "-nonewline" } {
	    if { [llength $args] == 3 } {
		if { [lindex $args 1] eq "stdout" } {
		    append ::httpd::cgiOutput [lindex $args 2]
		} else {
		    eval real_puts $args
		}
	    } else {
		append ::httpd::cgiOutput [lindex $args 1]
	    } 
	} else {
	    if { [llength $args] == 2 } {
		if { [lindex $args 0] eq "stdout" } {
		    append ::httpd::cgiOutput "[lindex $args 1]\r\n"
		} else {
		    eval real_puts $args
		}
	    } else {
		append ::httpd::cgiOutput "[lindex $args 0]\r\n"
	    }	   
	}
    }


    proc dumpenv {} {
	set fp [open c:/cgienv.sh w]
	foreach key [array names ::env] {
	    puts $fp "export $key=\"$::env($key)\""
	}
	close $fp

    }


    proc probe {} {
	real_puts "Stack trace:"
	for {set i [expr [info level] - 1]} {$i} {incr i -1} {
	    real_puts "  Processing '[info level $i]'."
	}
    } ;# JCW

    proc captureVars { } {
	puts "*BEGIN************************************"
	puts [info globals]
	puts "*************************************"
	puts [array get ::_cgi]
	puts "*END************************************"
	
    }

}

package provide wikithttpd $httpd::version 
