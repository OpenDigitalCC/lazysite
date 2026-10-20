#!/usr/bin/perl
# tools/bench-surfaces.pl - where each surface's time goes, per phase.
#
# SM1144 (SM1082 track T0). The sites agent measured an Odoo read at about 550 ms
# and a persistent-runtime plan hangs on that figure; the plan wants before-figures
# for every surface and a regression gate, taken without adding load to a shared
# host. This sends N requests, one at a time, to each surface the engine answers,
# reads the Server-Timing header each one carries (lib/Lazysite/Timing.pm), and
# reports the median and the 90th percentile of every phase - config, identity,
# load, render, call, write - and of the whole request.
#
# RUN IT THROUGH tools/bench-surfaces.sh, which pins it to one CPU at the lowest
# priority and is the only thing that sets BENCH_SURFACES_CONSTRAINED. Run bare it
# refuses: a benchmark that competes with the host's other work measures the host.
# It is sequential by construction (one blocking request at a time, no fork loop,
# no parallelism) and the pool it may start (--with-pool) has ONE worker.
#
#   tools/bench-surfaces.sh                    # N=3 against a throwaway site, CGI path
#   tools/bench-surfaces.sh --n 20             # a figure to quote
#   tools/bench-surfaces.sh --surface page,odoo
#   tools/bench-surfaces.sh --with-pool --cold-workers
#                                              # the pool recycles after ONE request, so every pooled
#                                              # request is a fresh worker's first: the cost of a worker
#                                              # start and respawn (SM1169, SM1082 C1), not of a warm one
#   tools/bench-surfaces.sh --with-pool        # and through a one-worker pool of its own
#   tools/bench-surfaces.sh --docroot D --socket S   # an existing pooled site: the
#                                                    # surfaces that need no login
#   tools/bench-surfaces.sh --json             # machine-readable
#   tools/bench-surfaces.sh --odoo-margin --margin-docroot D --margin-binding ID [--margin-query q=v] [--margin-ms 20]
#                                              # SM1180, advisory: the endpoint against a direct oomd call; WARN above the margin
#
# A throwaway site is built under a temporary directory and removed at the end:
# server_timing is on in it, an operator, a connector and a WebDAV account exist
# in it, and nothing outside it is written. With --docroot the site is read only
# as a client would: it needs `server_timing: on` in its lazysite.conf (or the
# header is not sent to an anonymous request and there is nothing to read), and
# only the surfaces an anonymous request reaches are measured.
use strict;
use warnings;
use Time::HiRes  qw(time sleep);
use File::Temp   qw(tempdir);
use File::Path   qw(make_path);
use File::Copy   ();
use JSON::PP     qw(encode_json decode_json);
use IPC::Open3   ();
use Symbol       ();
use Socket       qw(AF_UNIX SOCK_STREAM sockaddr_un);
use Digest::SHA  qw(hmac_sha256_hex);
use MIME::Base64 ();
use Getopt::Long ();
use FindBin;

( my $ROOT = $FindBin::Bin ) =~ s{/tools\z}{};
BEGIN {
    # Locate the Lazysite module tree relative to this script (run-in-place,
    # tar and Hestia installs), falling back to the system @INC (package
    # installs). No configuration needed.
    require Cwd;
    require File::Basename;
    my $bin = File::Basename::dirname( Cwd::abs_path(__FILE__) );
    for my $cand ( "$bin/lib", "$bin/../lib", "$bin/../../lib" ) {
        if ( -d "$cand/Lazysite" ) { unshift @INC, $cand; last }
    }
}
use Lazysite::Paths ();

my %opt = ( n => 3, surface => '', json => 0, docroot => '', socket => '', with_pool => 0, cold_workers => 0,
    odoo_margin => 0, margin_ms => 20, margin_docroot => '', margin_binding => '', margin_query => '' );
Getopt::Long::GetOptions(
    'n=i'              => \$opt{n},
    'surface=s'        => \$opt{surface},
    'json'             => \$opt{json},
    'docroot=s'        => \$opt{docroot},
    'socket=s'         => \$opt{socket},
    'with-pool'        => \$opt{with_pool},
    'cold-workers'     => \$opt{cold_workers},
    'odoo-margin'      => \$opt{odoo_margin},
    'margin-ms=f'      => \$opt{margin_ms},
    'margin-docroot=s' => \$opt{margin_docroot},
    'margin-binding=s' => \$opt{margin_binding},
    'margin-query=s'   => \$opt{margin_query},
    'help' => sub { print "see the header of tools/bench-surfaces.pl\n"; exit 0 },
) or exit 2;

die "bench-surfaces: run this through tools/bench-surfaces.sh, which pins it to one CPU at the "
    . "lowest priority. Run bare it would compete with the host's other work.\n"
    unless $ENV{BENCH_SURFACES_CONSTRAINED};
die "bench-surfaces: --n must be 1 or more\n" unless $opt{n} >= 1;
die "bench-surfaces: --cold-workers sets the pool --with-pool starts, so it needs --with-pool\n"
    if $opt{cold_workers} && !$opt{with_pool};
die "bench-surfaces: --socket needs --docroot (the site it belongs to)\n"
    if length $opt{socket} && !length $opt{docroot};

# --- the surfaces ------------------------------------------------------------
# name => the request that reaches it. `wrapped` runs the auth wrapper first, as
# the web server's rewrite does. `needs` names what the surface needs of the site
# (a login, SQLite), so a site that cannot give it is skipped and the skip said.
my @ALL = qw(page page-signed-in manager mcp data odoo odoo-direct dav);

# --- the site -----------------------------------------------------------------
my $tmp;
my ( $docroot, $LZ, %acct );
my $own_site = !length $opt{docroot};

sub users_api {
    my ($p) = @_;
    my $err = Symbol::gensym();
    my $pid = IPC::Open3::open3( my $in, my $out, $err, $^X, "$ROOT/tools/lazysite-users.pl", '--api', '--docroot', $docroot );
    print {$in} encode_json($p);
    close $in;
    my $o = do { local $/; <$out> } // '';
    { local $/; my $e = <$err>; }
    waitpid $pid, 0;
    return eval { decode_json($o) } // {};
}

sub users_cli {
    my (@a) = @_;
    my $err = Symbol::gensym();
    my $pid = IPC::Open3::open3( my $in, my $out, $err, $^X, "$ROOT/tools/lazysite-users.pl", '--docroot', $docroot, @a );
    close $in;
    my $o = do { local $/; <$out> };
    { local $/; my $e = <$err>; }
    waitpid $pid, 0;
    return $? >> 8;
}

sub put {
    my ( $path, $text ) = @_;
    open my $fh, '>', $path or die "$path: $!";
    print {$fh} $text;
    close $fh;
}

sub build_site {
    $tmp     = tempdir( CLEANUP => 1 );
    $docroot = "$tmp/site/public_html";
    make_path( $docroot, "$tmp/site/plugins" );
    $LZ = Lazysite::Paths::lazysite_dir($docroot);    # asked, never built (t/lint/37)
    make_path( "$LZ/auth", "$LZ/cache", "$LZ/layouts/bench" );
# The plugins the registry looks for beside the docroot (copies: SM152 refuses a symlink).
    opendir my $pd, "$ROOT/plugins" or die "plugins: $!";
    for my $f ( grep { /\A[A-Za-z0-9_.-]+\.pl\z/ } readdir $pd ) {
        File::Copy::copy( "$ROOT/plugins/$f", "$tmp/site/plugins/$f" );
    }
    closedir $pd;

    my $sqlite = eval { require DBI; require DBD::SQLite; require YAML::PP; 1 } ? 1 : 0;
    put( "$LZ/lazysite.conf",
        "site_name: Bench\nsite_url: http://localhost\nlayout: bench\nserver_timing: on\n"
            . "manager: enabled\ncontrol_api_enabled: true\nmcp_enabled: true\nwebdav_enabled: true\n"
            . "plugins:\n  - plugins/odoo.pl\n" . ( $sqlite ? "  - plugins/data.pl\n" : '' ) );
    put( "$LZ/layouts/bench/layout.tt",
        '<!DOCTYPE html><html><head><title>[% page_title %]</title></head><body>[% content %]</body></html>' );
    put( "$docroot/index.md",
        "---\ntitle: Home\n---\n\n# Hello\n\nA page with **markdown**, a [link](/about), and a list:\n\n- one\n- two\n- three\n" );
    put( "$docroot/404.md", "---\ntitle: Not Found\n---\nNot found.\n" );

    # The secret before anything is signed or verified (an absent one signs nothing).
    put( "$LZ/auth/.secret", 'b' x 64 );
    chmod 0600, "$LZ/auth/.secret";
    $acct{secret} = 'b' x 64;

    # An operator (setup-sysop grants the manager's capabilities), a connector
    # with the mcp capability and nothing else, and a WebDAV publisher.
    users_cli( 'setup-sysop', '--user',  'bench', 'bench-pw-0123456789' );
    users_cli( 'add',         'agent',   'agent-pw-0123456789' );
    users_cli( 'group-add',   'agent',   'g-agent' );
    users_cli( 'group-set',   'g-agent', 'mcp', 'on' );
    $acct{token} = users_api( { action => 'token', username => 'agent' } )->{token} // '';
    users_cli( 'add',       'davuser', 'dav-pw-0123456789' );
    users_cli( 'group-add', 'davuser', 'g-dav' );
    users_cli( 'group-set', 'g-dav',   $_, 'on' ) for qw(webdav manage_content);
    $acct{dav} = 'Basic ' . MIME::Base64::encode_base64( 'davuser:dav-pw-0123456789', '' );

    my $payload = 'bench:' . int( time() ) . ':';
    $acct{cookie} = 'lazysite_auth=' . $payload . ':' . hmac_sha256_hex( $payload, $acct{secret} );

    if ($sqlite) {
        make_path("$LZ/db/tables");
        put( "$LZ/db/tables/notes.yaml",
            "public: true\nkey: code\nfields:\n  code:\n    type: text\n    required: true\n" );
        unshift @INC, "$ROOT/lib";
        require Lazysite::Data::Tables;
        Lazysite::Data::Tables::apply_schema( $docroot, 'notes' );
    }
    $acct{sqlite} = $sqlite;
    return;
}

# --- the oomd margin check (SM1180) ---------------------------------------------------
# ADVISORY, never in the suite. The inbox (2026-10-19) asked that lazysite add at most
# ~10-20 ms to what oomd takes: "a timing check for the endpoint against oomd for one
# fixed operation, failing above a set margin". For one public read binding on an
# existing site whose oomd is running, this times the endpoint (one CGI request of
# lazysite-odoo.pl) against a direct oomd client call (a fresh perl that loads the
# light client and asks, as the lab's 61 ms), and prints a WARN line - exit 0 - when the
# endpoint adds more than the margin. BENCH_MARGIN_STUB="endpoint_ms,direct_ms" replaces
# the two measurements, so a test can drive the verdict without timing anything.
sub margin_check {
    my ( $e, $d );
    if ( defined $ENV{BENCH_MARGIN_STUB} ) {
        ( $e, $d ) = split /,/, $ENV{BENCH_MARGIN_STUB};
    }
    else {
        die "bench-surfaces: --odoo-margin needs --margin-docroot (a site with a running oomd) and "
            . "--margin-binding (a public read binding on it)\n"
            unless length $opt{margin_docroot} && length $opt{margin_binding};
        $docroot = $opt{margin_docroot};
        require Lazysite::Odoo;
        require Lazysite::Odoo::Daemon;
        no warnings 'once';
        $Lazysite::Odoo::DOCROOT = $docroot;
        my ( $b, $why ) = Lazysite::Odoo::find_binding( $opt{margin_binding} );
        die "bench-surfaces: $why\n" unless $b;
        my %q = map { split /=/, $_, 2 } grep { length } split /&/, $opt{margin_query};
        my %params = %{ $b->{fixed} };
        $params{ $b->{params}{$_} } = $q{$_} for grep { exists $b->{params}{$_} } keys %q;
        my ($sock) = Lazysite::Odoo::Daemon::socket_for($docroot);
        my %e      = base_env();
        my $s      = { script => 'lazysite-odoo.pl', pass_env => 1, anon => 1,
            env => { %e, QUERY_STRING => "binding=$opt{margin_binding}&$opt{margin_query}",
                REQUEST_URI => '/cgi-bin/lazysite-odoo.pl' } };
        my $code = 'use strict; use warnings; require Odoo::Ops::Client::Daemon; require JSON::PP; '
            . 'my ($sock,$op,$p)=@ARGV; Odoo::Ops::Client::Daemon->new(socket=>$sock,fallback=>0)'
            . '->run($op,JSON::PP::decode_json($p),credential=>{label=>"conn"},actor=>"bench"); 1';
        my $direct = sub {
            my $t0 = time();
            system( $^X, '-e', $code, $sock, $b->{operation}, JSON::PP::encode_json( \%params ) ) == 0
                or die "bench-surfaces: the direct oomd call failed (is oomd running at $sock?)\n";
            return ( time() - $t0 ) * 1000;
        };
        run_cgi($s);
        $direct->();    # warm
        my ( @ev, @dv );
        for ( 1 .. $opt{n} ) {
            my $r = run_cgi($s);
            die "bench-surfaces: the endpoint did not answer 200 for the binding (status $r->{status})\n"
                unless $r->{status} == 200;
            push @ev, $r->{total};
            push @dv, $direct->();
        }
        ( $e, $d ) = ( median(@ev), median(@dv) );
    }
    my $add = $e - $d;
    printf "bench-margin: endpoint %.1f ms, direct oomd client %.1f ms, the endpoint adds %.1f ms (margin %g ms)\n",
        $e, $d, $add, $opt{margin_ms};
    printf "bench-margin: WARN the endpoint adds %.1f ms to what oomd takes, more than the %g ms margin\n",
        $add, $opt{margin_ms}
        if $add > $opt{margin_ms};
    return;
}

if ( $opt{odoo_margin} ) { margin_check(); exit 0 }

if ($own_site) { build_site() }
else {
    $docroot = $opt{docroot};
    die "bench-surfaces: $docroot is not a directory\n" unless -d $docroot;
    $LZ = Lazysite::Paths::lazysite_dir($docroot);
    my $conf = do { open my $fh, '<', "$LZ/lazysite.conf" or die "$LZ/lazysite.conf: $!\n"; local $/; <$fh> };
    die "bench-surfaces: $LZ/lazysite.conf does not say `server_timing: on`, so an anonymous request "
        . "is sent no Server-Timing header and there is nothing to read. Turn it on for the measurement and off after.\n"
        unless $conf =~ /^server_timing\h*:\h*(?:on|true|yes|1|enabled)\h*$/mi;
}

# --- requests ----------------------------------------------------------------
sub base_env {
    return (
        DOCUMENT_ROOT  => $docroot,
        REQUEST_METHOD => 'GET',
        QUERY_STRING   => '',
        REMOTE_ADDR    => '127.0.0.1',
        HTTP_HOST      => 'localhost',
    );
}

# name => { script, env, stdin, wrapped, uri, anon }
sub spec_for {
    my ($name) = @_;
    my %e      = base_env();
    my %s      = (
        'page' => { script => 'lazysite-processor.pl', anon => 1, uri => '/',
            env => { %e, REDIRECT_URL => '/', REQUEST_URI => '/' } },
        'page-signed-in' => { script => 'lazysite-processor.pl', wrapped => 1, uri => '/',
            env => { %e, REDIRECT_URL => '/', REQUEST_URI => '/', HTTP_COOKIE => $acct{cookie} } },
        'manager' => { script => 'lazysite-manager-api.pl', wrapped => 1, uri => '/cgi-bin/lazysite-manager-api.pl?action=whoami',
            env => { %e, QUERY_STRING => 'action=whoami', REQUEST_URI => '/cgi-bin/lazysite-manager-api.pl?action=whoami',
                HTTP_COOKIE => $acct{cookie} } },
        'mcp' => { script => 'lazysite-mcp.pl', uri => '/cgi-bin/lazysite-mcp.pl',
            env => { %e, REQUEST_METHOD => 'POST', REQUEST_URI => '/cgi-bin/lazysite-mcp.pl',
                HTTP_AUTHORIZATION => "Bearer agent:$acct{token}" },
            stdin => encode_json( { jsonrpc => '2.0', id => 1, method => 'tools/call',
                    params => { name => 'whoami', arguments => {} } } ) },
        'data' => { script => 'lazysite-data.pl', uri => '/cgi-bin/lazysite-data.pl?table=notes',
            env => { %e, QUERY_STRING => 'table=notes', REQUEST_URI => '/cgi-bin/lazysite-data.pl?table=notes',
                HTTP_COOKIE => $acct{cookie} }, needs => 'sqlite' },
        'odoo' => { script => 'lazysite-odoo.pl', wrapped => 1, anon => 1, uri => '/cgi-bin/lazysite-odoo.pl?csrf=1',
            env => { %e, QUERY_STRING => 'csrf=1', REQUEST_URI => '/cgi-bin/lazysite-odoo.pl?csrf=1' } },
        'odoo-direct' => { script => 'lazysite-odoo.pl', anon => 1, uri => '/cgi-bin/lazysite-odoo.pl?csrf=1',
            env => { %e, QUERY_STRING => 'csrf=1', REQUEST_URI => '/cgi-bin/lazysite-odoo.pl?csrf=1' } },
        'dav' => { script => 'lazysite-dav.pl', uri => '/dav/',
            env => { %e, REQUEST_METHOD => 'PROPFIND', PATH_INFO => '/', SCRIPT_NAME => '/dav', REQUEST_URI => '/dav/',
                HTTP_AUTHORIZATION => $acct{dav}, HTTP_DEPTH => '0', LAZYSITE_DAV_FAIL_DELAY => 0 } },
    );
    return $s{$name};
}

sub parse_response {
    my ( $raw, $ms ) = @_;
    my ($head) = split /\r?\n\r?\n/, $raw, 2;
    $head //= '';
    my ($st) = $head =~ /^Status:\s*(\d+)/m;
    my %ph;
    if ( $head =~ /^Server-Timing:\s*(.*?)\r?$/m ) {
        for my $m ( split /,\s*/, $1 ) {
            $ph{$1} = $2 + 0 if $m =~ /\A([a-z]+);dur=([\d.]+)\z/;
        }
    }
    return { status => $st // 200, total => $ms, phases => \%ph };
}

# One CGI request: a process, as the web server would start one.
sub run_cgi {
    my ($s)    = @_;
    my %env    = %{ $s->{env} };
    my $script = "$ROOT/$s->{script}";
    if ( $s->{wrapped} ) {
        $env{LAZYSITE_PROCESSOR} = $script;
        $script = "$ROOT/lazysite-auth.pl";
    }
    $env{CONTENT_LENGTH} = length $s->{stdin} if defined $s->{stdin};
    $env{PATH}           = $ENV{PATH};
    $env{PERL5LIB} = $ENV{PERL5LIB} if $s->{pass_env} && defined $ENV{PERL5LIB}; # SM1180: OOM may live on PERL5LIB
    local %ENV = %env;
    my $t0  = time();
    my $err = Symbol::gensym();
    my $pid = IPC::Open3::open3( my $in, my $out, $err, $^X, $script );
    binmode $in;
    print {$in} $s->{stdin} if defined $s->{stdin};
    close $in;
    my $o = do { local $/; <$out> } // '';
    my $e = do { local $/; <$err> };         # drained so a chatty child cannot block
    waitpid $pid, 0;
    return parse_response( $o, ( time() - $t0 ) * 1000 );
}

# --- a minimal FastCGI client (the one in t/lib is for the suite) ----------------
sub _rec {
    my ( $type, $c ) = @_;
    my $pad = ( 8 - ( length($c) % 8 ) ) % 8;
    return pack( 'CCnnCC', 1, $type, 1, length $c, $pad, 0 ) . $c . ( "\0" x $pad );
}

sub _nv {
    my ( $n, $v ) = @_;
    return join '', ( map { $_ < 128 ? pack( 'C', $_ ) : pack( 'N', $_ | 0x80000000 ) } length $n, length $v ), $n, $v;
}

sub fcgi_request {
    my ( $path, $params, $body ) = @_;
    $body //= '';
    socket( my $sk, AF_UNIX, SOCK_STREAM, 0 ) or die "socket: $!";
    connect( $sk, sockaddr_un($path) )        or die "connect $path: $!";
    binmode $sk;
    local $SIG{PIPE} = 'IGNORE';
    my $req = _rec( 1, pack( 'nCx5', 1, 0 ) )
        . _rec( 4, join '', map { _nv( $_, $params->{$_} // '' ) } sort keys %$params )
        . _rec( 4, '' )
        . ( length $body ? _rec( 5, $body ) : '' )
        . _rec( 5, '' );
    my $off = 0;
    while ( $off < length $req ) {
        my $w = syswrite( $sk, $req, length($req) - $off, $off );
        die "syswrite: $!" unless defined $w;
        $off += $w;
    }
    my ( $out, $buf ) = ( '', '' );
    while (1) {
        my $r = sysread( $sk, $buf, 65536, length $buf );
        last if !defined $r || $r == 0;
        while ( length $buf >= 8 ) {
            my ( undef, $type, undef, $clen, $plen ) = unpack 'CCnnC', $buf;
            last if length $buf < 8 + $clen + $plen;
            my $c = substr $buf, 8, $clen;
            $buf = substr $buf, 8 + $clen + $plen;
            $out .= $c if $type == 6;
            if ( $type == 3 ) { close $sk; return $out }
        }
    }
    close $sk;
    return $out;
}

sub run_pool {
    my ( $s, $sock ) = @_;
    my %p = %{ $s->{env} };
    $p{SCRIPT_NAME} //= $s->{uri};
    $p{CONTENT_LENGTH} = length $s->{stdin} if defined $s->{stdin};
    my $t0  = time();
    my $raw = fcgi_request( $sock, \%p, $s->{stdin} );
    return parse_response( $raw, ( time() - $t0 ) * 1000 );
}

# --- a pool of our own: one worker, started and stopped here --------------------
my $pool_pid;
sub start_pool {
    my $sock = "$tmp/bench.sock";
    my $pid  = fork() // die "fork: $!";
    if ( !$pid ) {
        my $user = getpwuid($<) // $ENV{USER} // 'nobody';
        local %ENV = ( PATH => $ENV{PATH}, DOCROOT => $docroot, USER => $user, WORKERS => 1, MAX_REQUESTS => ( $opt{cold_workers} ? 1 : 500 ),
            FRONT_DOOR => 1, CGIBIN => $ROOT, SOCKET => $sock );
        open STDOUT, '>', '/dev/null' or exit 127;
        open STDERR, '>', '/dev/null' or exit 127;
        exec( $^X, "$ROOT/tools/lazysite-pool.pl", '--instance', 'bench', '--socket', $sock, '--run-dir', $tmp )
            or exit 127;
    }
    $pool_pid = $pid;
    for ( 1 .. 100 ) {
        return $sock if -S $sock;
        sleep 0.05;
    }
    stop_pool();
    return undef;
}

sub stop_pool {
    return unless $pool_pid;
    kill 'TERM', $pool_pid;
    waitpid $pool_pid, 0;
    $pool_pid = undef;
    return;
}
END { stop_pool() }

# --- statistics ----------------------------------------------------------------
sub median {
    my @v = sort { $a <=> $b } @_;
    return undef unless @v;
    return @v % 2 ? $v[ $#v / 2 ] : ( $v[ @v / 2 - 1 ] + $v[ @v / 2 ] ) / 2;
}

sub p90 {
    my @v = sort { $a <=> $b } @_;
    return undef unless @v;
    my $i = int( 0.9 * @v + 0.999999 ) - 1;
    $i = $#v if $i > $#v;
    return $v[$i];
}

sub summarise {
    my ( $name, $path, @res ) = @_;
    my %by;
    for my $r (@res) {
        push @{ $by{total} }, $r->{total};
        my $sum = 0;
        for my $k ( keys %{ $r->{phases} } ) {
            push @{ $by{$k} }, $r->{phases}{$k};
            $sum += $r->{phases}{$k};
        }
        # What no phase accounts for: the interpreter starting, the response
        # leaving, the process exiting.
        push @{ $by{other} }, $r->{total} - $sum;
    }
    my %out = ( surface => $name, path => $path, n => scalar @res, status => $res[-1]{status} );
    for my $k ( keys %by ) {
        $out{phases}{$k} = { median => median( @{ $by{$k} } ), p90 => p90( @{ $by{$k} } ) };
    }
    return \%out;
}

# --- run -----------------------------------------------------------------------
my @want = length $opt{surface} ? split( /,/, $opt{surface} ) : @ALL;
for my $w (@want) { die "bench-surfaces: unknown surface '$w' (known: @ALL)\n" unless grep { $_ eq $w } @ALL }

my $pool_sock = $opt{socket};
if ( $opt{with_pool} ) {
    die "bench-surfaces: --with-pool builds its own site, so it cannot be combined with --docroot\n" unless $own_site;
    $pool_sock = start_pool();
    warn "bench-surfaces: the pool did not start; the CGI path only\n" unless $pool_sock;
}

my ( @report, @skipped );
for my $name (@want) {
    my $spec = spec_for($name);
    if ( !$own_site && !$spec->{anon} ) {
        push @skipped, "$name (needs a login; a site that is not the throwaway one is measured as a client)";
        next;
    }
    if ( ( $spec->{needs} // '' ) eq 'sqlite' && !$acct{sqlite} ) {
        push @skipped, "$name (DBD::SQLite or YAML::PP is not installed)";
        next;
    }
    # Pooled sites answer these themselves or relay them; a site not run as a
    # pool has no socket and is measured as CGI only.
    my @paths = ( [ cgi => sub { run_cgi($spec) } ] );
    push @paths, [ pool => sub { run_pool( $spec, $pool_sock ) } ] if $pool_sock && ( $own_site || $spec->{anon} );
    for my $p (@paths) {
        my ( $label, $run ) = @$p;
        $run->(); # warm: the first request writes the page cache and the compiled templates
        my @res = map { $run->() } 1 .. $opt{n};
        push @report, summarise( $name, $label, @res );
    }
}

my @ORDER = qw(config identity load render call write other);
if ( $opt{json} ) {
    print JSON::PP->new->canonical->pretty->encode( { n => $opt{n}, engine => $ROOT, surfaces => \@report, skipped => \@skipped } );
}
else {
    printf "bench-surfaces: %d request%s per surface, sequential, one CPU, nice 19; ms, median/p90\n",
        $opt{n}, $opt{n} == 1 ? '' : 's';
    for my $r (@report) {
        my $p = $r->{phases};
        my @cells = map { sprintf '%s %.1f/%.1f', $_, $p->{$_}{median}, $p->{$_}{p90} } grep { $p->{$_} } @ORDER;
        printf "%-15s %-4s status %-3s total %.1f/%.1f   %s\n", $r->{surface}, $r->{path}, $r->{status},
            $p->{total}{median}, $p->{total}{p90}, join( '  ', @cells );
    }
    print "skipped: $_\n" for @skipped;
}
exit 0;
