package main;

# lazysite-processor/front-door.pm - the processor's front door (SM294).
#
# HOLDS   _front_door(): under LAZYSITE_FRONT_DOOR, a pool worker routes each
#         request itself - a page, a content static or a denial is answered in
#         this process, another surface or a wrapped request is relayed to a
#         child; _front_route($req), the module-free copy of
#         Lazysite::FrontDoor::route (t/lint/42 drives both); _front_relay and
#         its helpers _front_cgibin, _read_request_body, _front_body_cap
#         (SM389: the body is bounded before it is read) and _front_fail; and
#         @POOL_PRELOAD with _pool_preload (SM1169), the engine modules the
#         pool's parent loads before it forks its workers.
# OWNS    which requests a pool worker answers itself and which it relays; which
#         modules the pool's parent loads for its workers.
# CALLS   _lazysite_dir_for, _conf_value, _security_headers, log_event, _lazy_lib
#         (lazysite-processor.pl); IO::Select and POSIX, required inside
#         _front_relay at call time, as before.
# READS   $DOCROOT, $FRONT_CGIBIN, $RELAY_TIMEOUT, %ACCESS_REC (the script's,
#         declared `our` there). Whether the front door is on ($FRONT_DOOR) is
#         the script's own decision, read where it calls _front_door.
#
# A PART OF THE PROCESSOR, NOT A MODULE (SM944 S9). It is package main, required
# by absolute path from lazysite-processor.pl's BEGIN and never through @INC, and
# it loads nothing - ADR 0001 keeps the render path free of the Lazysite:: tree.
use strict;
use warnings;

our ( $DOCROOT, $FRONT_CGIBIN, $RELAY_TIMEOUT, %ACCESS_REC );

# --- Preload before fork (SM1169, SM1082 C1) ---

# THE ENGINE MODULES A POOLED REQUEST LOADS ON FIRST USE, named once. Each is
# loaded by _lazy_lib at the point a request needs it (ADR 0001 keeps the CGI
# render path free of them), so under the pool every worker paid for each on its
# own first request - and again for every respawn, which is every
# LAZYSITE_FCGI_MAX_REQUESTS requests. The pool PARENT loads them once, before
# FCGI::ProcManager forks, and a worker inherits them copy-on-write.
#
# THE LIST IS THE LAZY LOADS, NOT A GUESS: t/lint/269 holds it to the modules the
# processor and its parts name through _lazy_lib or `require Lazysite::...`, so a
# module added to the request path and left off this list fails there. The `use`
# closure of each comes with it, and t/lint/269 reads every file-scope variable of
# that whole set (the SM973 class: a variable a worker keeps from one visitor to
# the next).
#
# Only the pool's branch calls _pool_preload. A plain CGI request is a fresh
# process and loads what it needs, as before.
our @POOL_PRELOAD = qw(
    Lazysite::Auth::Identity
    Lazysite::Auth::AddressLists
    Lazysite::Auth::AddressAudit
    Lazysite::Auth::AddressScope
    Lazysite::I18n
    Lazysite::Fetch
    Lazysite::Data::Tables
    Lazysite::Odoo
    Lazysite::Odoo::Fields
    Lazysite::Odoo::Identity
    Lazysite::Odoo::Visitor
);

# Load the modules, then compile one trivial template and one trivial page of
# Markdown so Template's parser and Text::MultiMarkdown's rules are in the parent
# too: they compile on first use, not on `use`, and are most of what a worker's
# first page costs. Nothing is written (no compile directory, no cache) and
# nothing a request owns is touched: no request has been read yet, so there is no
# person in the process to carry.
#
# A module that will not load (an optional dependency absent, say) is logged and
# skipped: the worker then loads it, or fails to, exactly as it did before.
sub _pool_preload {
    my @failed;
    for my $m (@POOL_PRELOAD) {
        eval { _lazy_lib($m); 1 } or push @failed, $m;
    }
    log_event( 'INFO', 'pool', 'preload skipped a module that did not load', modules => join( ',', @failed ) )
        if @failed;
    eval {
        my $tt  = Template->new( {} );
        my $out = '';
        $tt->process( \'[% FOREACH i IN [1] %][% i | html %][% END %][% IF x %]y[% END %]', {}, \$out );
        Text::MultiMarkdown->new->markdown("*a*\n\n| h |\n|---|\n| c |\n");
        1;
    };
    return scalar(@POOL_PRELOAD) - scalar(@failed);
}

# --- The front door (SM294) ---

# SM293 step 5 put every routing decision the vhost templates used to make into
# Lazysite::FrontDoor::route(), and shipped lazysite-front.pl to execute it - so a
# front end can be ONE rule. That script dispatches with exec(), which is exactly
# right for a one-shot CGI and fatal here: exec REPLACES the process, so a worker
# that dispatched that way would cease to exist and the next request would find
# nothing listening. The failure is invisible to a single request, which answers
# perfectly on the way out.
#
# So the worker consults the same table and splits by what it can BE:
#
#   - the hot path (a page, a content static, a denial) is what this process
#     already is, so it is answered in-process at no cost - and that is the
#     overwhelming majority of requests, which is the whole point of the pool;
#   - the cold path (another surface, or anything needing the auth wrapper) is
#     RELAYED to a child, costing a process on exactly the requests that cost one
#     today. Never worse than the CGI front door, much better than it on the rest.
#
# Off unless LAZYSITE_FRONT_DOOR is set, so an existing pool is byte-identical.
#
# Module-free (ADR 0001), mirroring Lazysite::FrontDoor::route; t/lint/42 drives
# BOTH and compares answers, because the two must not drift into a front end and
# an engine that disagree about who owns a URL - which is SM248, SM268 H17 and
# SM283, all three.
sub _front_route {
    my ($req)   = @_;
    my $docroot = $req->{docroot} // '';
    my $uri     = $req->{uri}     // '/';
    my $cookie  = $req->{cookie}  // '';
    $docroot =~ s{/+\z}{};
    $uri     =~ s/\?.*\z//s;

    return { surface => 'denied', why => 'engine-owned path' }
        if $uri =~ m{\A/lazysite(?:/|\z)} || $uri =~ /[.]brief\z/;

    if ( $uri =~ m{\A/cgi-bin/(lazysite-[a-z-]+[.]pl)\z} ) {
        my $script = $1;
        my $wrap
            = ( $script =~ /\A lazysite-(?:processor|manager-api)[.]pl \z/x )
            ? 1
            : 0;
        return { surface => 'cgi', target => $script, wrapped => $wrap,
            why => 'named cgi surface' };
    }

    # SM1182: the two plugins install.pl links into cgi-bin under their own names
    #    (no lazysite- prefix). Every native form posts to /cgi-bin/form-handler.pl;
    #    under the one rule it matched nothing above and fell to the processor as a
    #    page miss, so a form was never delivered. By NAME, never a wider pattern:
    #    only what the installer ships there is reachable. Both run direct, outside
    #    the auth wrapper, as they do installed (SM402: the handler reads no identity).
    if ( $uri =~ m{\A/cgi-bin/(form-handler|payment-demo)[.]pl\z} ) {
        return { surface => 'cgi', target => "$1.pl", wrapped => 0,
            why => 'linked plugin cgi' };
    }

    return { surface => 'cgi', target => 'lazysite-dav.pl', wrapped => 0,
        why => 'dav prefix' }
        if $uri =~ m{\A/dav(?:/|\z)};

    my $lz       = _lazysite_dir_for($docroot);
    my $has_acls = ( -f "$lz/auth/acls.json" ) ? 1 : 0;
    ( my $rel = $uri ) =~ s{\A/+}{};

    if ( $has_acls && length $rel && -f "$docroot/$rel" ) {
        return { surface => 'processor', wrapped => 1,
            why => 'existing static, acl store present' };
    }

    if ( $uri =~ m{\A/([^.]+)\z} ) {
        my $stem = $1;
        if ( !-f "$docroot/$stem.md" ) {
            my $legacy
                = ( -f "$docroot/$stem.html" )  ? "$stem.html"
                : ( -f "$docroot/$stem.shtml" ) ? "$stem.shtml"
                :                                 undef;
            if ( defined $legacy ) {
                return { surface => 'processor', wrapped => 1,
                    why => 'legacy static page, acl store present' }
                    if $has_acls;
                return { surface => 'static', target => $legacy,
                    why => 'legacy static page' };
            }
        }
    }

    if ( $uri eq '/' && !-f "$docroot/index.md" && -f "$docroot/index.html" ) {
        return { surface => 'processor', wrapped => 1,
            why => 'legacy index, acl store present' }
            if $has_acls;
        return { surface => 'static', target => 'index.html',
            why => 'legacy index' };
    }

    if ( $cookie =~ /lazysite_auth=/ && !( length $rel && -f "$docroot/$rel" ) )
    {
        return { surface => 'processor', wrapped => 1,
            why => 'session cookie present' };
    }

    return { surface => 'static', target => $rel, why => 'existing static' }
        if length $rel && -f "$docroot/$rel";

    return { surface => 'processor', wrapped => 0, why => 'page miss' };
}

# Where the surfaces live. Same resolution as lazysite-front.pl, so the CGI and
# the pool front doors cannot disagree about it.
sub _front_cgibin {
    return $FRONT_CGIBIN if length $FRONT_CGIBIN;
    my $parent = $DOCROOT;
    $parent =~ s{/[^/]*\z}{};
    return "$parent/cgi-bin";
}

# SM389: read the request body, bounded. Returns ( $body, $too_big ).
#
# Its own sub rather than inline in the relay so it can be DRIVEN by a test with
# a real filehandle. The behaviour being claimed here is "a hostile body does not
# size this worker", and that is not a claim a source-text match can settle.
sub _read_request_body {
    my ($cap) = @_;
    my $body  = '';
    my $len   = ( $ENV{CONTENT_LENGTH} || 0 ) + 0;

    if ( $len > 0 ) {

        # Refuse before allocating, as the manager's upload path already does.
        # Reading it in order to find out how big it is would BE the defect.
        return ( '', 1 ) if $len > $cap;
        my $got = 0;
        while ( $got < $len ) {
            my $n = read STDIN, $body, $len - $got, $got;
            last if !defined $n || $n == 0;
            $got += $n;
        }
        return ( $body, 0 );
    }

    return ( '', 0 )
        unless ( $ENV{REQUEST_METHOD} // 'GET' ) =~ /\A(?:POST|PUT|PATCH)\z/;

    # No declared length - chunked transfer encoding, which the CLIENT chooses.
    # Read in bounded chunks and stop one byte past the cap: that is enough to
    # know it is over, and finding out HOW far over would mean reading it all,
    # which is the thing being prevented.
    my $got = 0;
    while ( $got <= $cap ) {
        my $n = read STDIN, $body, 65_536, $got;
        last if !defined $n || $n == 0;
        $got += $n;
    }
    return ( '',    1 ) if $got > $cap;
    return ( $body, 0 );
}

# SM389: how much request body the relay will hold in memory.
#
# THIS IS A MEMORY BACKSTOP, NOT A POLICY GATE. Policy lives downstream - the
# manager's manager_upload_max_mb, the form handler's upload_max_kb, WebDAV's
# own limit - and each refuses with an error that names the setting the sysop
# can change. The relay must never be the thing that quietly refuses a body
# those layers would have accepted.
#
# So it follows the upload limit UP. A sysop who raises
# manager_upload_max_mb is entitled to have uploads work; a fixed ceiling
# underneath it would present as "uploads broke after a config change" with
# nothing pointing at this function. front_max_body_mb overrides both, for the
# sysop who wants the backstop somewhere else entirely.
sub _front_body_cap {
    my $mb = 64;                                                # generous default ceiling
    my $up = ( _conf_value('manager_upload_max_mb') || 0 ) + 0;
    $mb = $up if $up > $mb;
    my $own = ( _conf_value('front_max_body_mb') || 0 ) + 0;
    $mb = $own if $own > 0;
    return $mb * 1024 * 1024;
}

sub _front_fail {
    my ( $status, $text ) = @_;
    $ACCESS_REC{s}  = $status;
    $ACCESS_REC{ch} = 'front';
    print "Status: $status\r\n";
    print "$_\r\n" for _security_headers();    # SM381
    print "Content-Type: text/plain; charset=utf-8\r\n\r\n";
    print "$text\n";
    return 1;
}

# How long a relayed surface may take before the worker gives up on it. A worker
# blocked forever on a wedged child serves NOTHING else - one hung request would
# take the site down, which is the failure mode the dev server already taught
# this project once (L-DEVBIND). Generous, because a large DAV upload is a
# legitimate slow request; finite, because the pool must survive a bad one.

# Run another surface as a child and pass its response through.
#
# The child gets real file descriptors 0 and 1 (a pipe each), NOT this worker's
# tied FCGI handles - those are Perl-level objects that do not survive exec, so
# the hand-off has to happen at the descriptor level or the child's output goes
# to the listen socket.
sub _front_relay {
    my ($decision) = @_;
    require IO::Select;
    require POSIX;

    my $cgibin = _front_cgibin();
    my $target
        = ( $decision->{surface} eq 'cgi' )
        ? "$cgibin/$decision->{target}"
        : "$cgibin/lazysite-processor.pl";

    return _front_fail( '500 Internal Server Error',
        "lazysite: surface not found: $decision->{target}" )
        unless -f $target;

    # The auth wrapper's contract is UNCHANGED: it validates the session cookie,
    # sets the trust headers, and execs whatever LAZYSITE_PROCESSOR names. Only
    # the choice of which requests get wrapped moved; how wrapping works did not,
    # so the trust design and the t/lint/38 gate are untouched. Folding the
    # wrapper in-process means replacing those headers with an identity value,
    # which is an auth-spine change and has its own filing.
    my $program = $target;
    if ( $decision->{wrapped} ) {
        my $wrapper = "$cgibin/lazysite-auth.pl";
        return _front_fail( '500 Internal Server Error',
            'lazysite: auth wrapper not found' )
            unless -f $wrapper;
        $ENV{LAZYSITE_PROCESSOR} = $target;
        $program = $wrapper;
    }

    # Read the request body before forking: it comes off this worker's tied FCGI
    # STDIN, which the child cannot inherit.
    #
    # SM389: BOUNDED, both ways. A declared CONTENT_LENGTH was trusted whatever
    # it said, and a request with no CONTENT_LENGTH at all - chunked transfer
    # encoding, which a client chooses, not the sysop - was slurped whole
    # under `local $/`. Either one sizes this worker to the body, and the worker
    # PERSISTS: the memory does not come back when the request ends.
    my ( $body, $too_big ) = _read_request_body( _front_body_cap() );
    return _front_fail( '413 Payload Too Large', 'lazysite: request body too large' )
        if $too_big;

    pipe my $from_kid, my $kid_out or
        return _front_fail( '500 Internal Server Error', 'lazysite: pipe' );
    pipe my $kid_in, my $to_kid or
        return _front_fail( '500 Internal Server Error', 'lazysite: pipe' );

    # FCGI::ProcManager installs a SIGCHLD reaper for ITS children; if it reaps
    # ours first, waitpid below never sees an exit status and we would block.
    local $SIG{CHLD} = 'DEFAULT';
    local $SIG{PIPE} = 'IGNORE';    # a child that dies mid-body must not kill us

    my $kid = fork();
    return _front_fail( '500 Internal Server Error', 'lazysite: fork' )
        unless defined $kid;

    if ( $kid == 0 ) {
        close $from_kid;
        close $to_kid;
        POSIX::dup2( fileno($kid_in),  0 );
        POSIX::dup2( fileno($kid_out), 1 );
        close $kid_in;
        close $kid_out;
        # _exit, not exit: this child is a fork of a FastCGI worker and must not
        # run its parent's END blocks or flush its parent's buffers on the way
        # out. The parent sees empty output and answers 500.
        exec {$^X} $^X, $program or POSIX::_exit(127);
    }

    close $kid_out;
    close $kid_in;

    my $rsel = IO::Select->new($from_kid);
    my $wsel = IO::Select->new();
    if   ( length $body ) { $wsel->add($to_kid) }
    else                  { close $to_kid }

    my $sent     = 0;
    my $written  = 0;
    my $deadline = time + $RELAY_TIMEOUT;
    my $timedout = 0;

    while ( $rsel->count || $wsel->count ) {
        my $left = $deadline - time;
        if ( $left <= 0 ) { $timedout = 1; last }
        my ( $r, $w ) = IO::Select->select( $rsel, $wsel, undef, $left );
        for my $h ( @{ $w || [] } ) {
            my $n = syswrite $h, $body, length($body) - $written, $written;
            if ( !defined $n ) { $wsel->remove($h); close $h; next }
            $written += $n;
            if ( $written >= length $body ) { $wsel->remove($h); close $h }
        }
        for my $h ( @{ $r || [] } ) {
            my $buf = '';
            my $n   = sysread $h, $buf, 65_536;
            if ( !defined $n || $n == 0 ) { $rsel->remove($h); close $h; next }
            print $buf;
            $sent += $n;
        }
    }

    if ($timedout) {
        kill 'TERM', $kid;
        select undef, undef, undef, 0.2;    ## no critic (ProhibitSleepViaSelect)
        kill 'KILL', $kid;
    }
    waitpid $kid, 0;
    my $rc = $?;

    if ($timedout) {
        log_event( 'ERROR', $ENV{REDIRECT_URL} // '-', 'relay timed out',
            surface => $decision->{target} // $decision->{surface},
            seconds => $RELAY_TIMEOUT );
        # Headers are already gone if anything was sent; truncating is all that
        # is left, and it is what any CGI host does. Say so in the log either way.
        return _front_fail( '504 Gateway Timeout', 'lazysite: surface timed out' )
            unless $sent;
        $ACCESS_REC{s} = 504;
        return 1;
    }

    unless ($sent) {
        log_event( 'ERROR', $ENV{REDIRECT_URL} // '-', 'relay produced nothing',
            surface => $decision->{target} // $decision->{surface}, rc => $rc );
        return _front_fail( '500 Internal Server Error',
            'lazysite: surface produced no response' );
    }

    # The child emitted its own CGI status line; record what we can for the
    # access log without re-parsing its headers.
    $ACCESS_REC{s}  = 200 unless defined $ACCESS_REC{s};
    $ACCESS_REC{ch} = 'front';
    return 1;
}

# Consult the front door. Returns true when the request has been answered here,
# false to fall through to main() - which is the hot path and must stay cheap.
sub _front_door {
    my $uri      = $ENV{REDIRECT_URL} // $ENV{REQUEST_URI} // '/';
    my $decision = _front_route(
        { docroot => $DOCROOT,
            uri    => $uri,
            method => ( $ENV{REQUEST_METHOD} // 'GET' ),
            cookie => ( $ENV{HTTP_COOKIE}    // '' ),
        }
    );

    # 404 rather than 403, matching lazysite-front.pl: a 403 confirms the path
    # exists, and these are paths whose existence is not the visitor's business.
    # (Reached only under the front door. The processor's own guard on the same
    # paths answers 403 and is left alone here - noted in the SM294 filing.)
    if ( $decision->{surface} eq 'denied' ) {
        $ACCESS_REC{s}  = 404;
        $ACCESS_REC{ch} = 'front';
        print "Status: 404 Not Found\r\n";
        print "Content-Type: text/html; charset=utf-8\r\n";
        print "$_\r\n" for _security_headers( html => '<p>Not found</p>' );    # SM352
        print "\r\n";
        print "<p>Not found</p>\n";
        return 1;
    }

    # What this process already is: render it here. 'static' included, because
    # the processor serves content statics itself (_serve_content_static) - the
    # front door does not reimplement byte ranges, conditional GETs or content
    # types, three things that are easy to get subtly wrong.
    return 0
        if !$decision->{wrapped}
        && ( $decision->{surface} eq 'processor'
        || $decision->{surface} eq 'static' );

    return _front_relay($decision);
}

1;
