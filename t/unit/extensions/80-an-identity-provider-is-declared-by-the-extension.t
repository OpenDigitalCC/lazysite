#!/usr/bin/perl
# SM1369 X4 (H-1, ruling 55; rulings 178, 186): AN IDENTITY PROVIDER IS DECLARED BY
# ITS EXTENSION, AND CORE KEEPS THE SESSION.
#
# A fixture extension declares owns.hooks.identity_provider - on, still_valid,
# groups, login_option, banner, renew, signin_page - and is enabled through the
# real manager, which indexes it. Its functions read a state file, so each case
# below sets what the provider answers. Then, through Lazysite::Auth::Session and
# the real processor:
#
#   * the declaration is checked: a core page name, a renew path off the site, a
#     grants that is not 0 or 1, or a provider without on/still_valid/groups is
#     refused; two extensions cannot declare one sign-in page;
#   * a session the provider asks for is core's: the cookie `probe=<login>` signed
#     with the site key and carrying no group, a record naming the provider; the
#     identity `probe:<login>` with the groups the provider still grants;
#   * G-1, off means off: the extension disabled (or out of the conf) mints and
#     verifies nothing, and the provider's own `on` saying no ends its sessions;
#   * G-3: a group that carries a capability is refused by core, by name in the
#     log, unless the provider declares `grants` - and a sign-in or renewal through
#     a granting provider writes an audit row naming the groups it granted;
#   * G-9: a provider function that dies or answers something else is no session;
#   * stale: refused with the provider's renew path, and with stale_ok it is the
#     identity with no groups;
#   * a record written before X4 (the provider's id as a flag, no `provider`)
#     verifies; a record of another provider over the same sid does not;
#   * the processor: the sign-in page is a system page while `on` says so and 404
#     otherwise, /login offers the provider's option (escaped), the fallback chrome
#     carries `signin_banner`, the sign-in page stays reachable in maintenance, and
#     none of it while the extension is off.
#
# Sabotage (each run by hand, each fails here): drop the enabled check from
# Hooks::identity_provider (G-1); drop the capability filter from
# _verify_provider_session (G-3); treat a failed `on` as on (G-9); drop the
# provider check from _provider_record (another provider's record).
use strict;
use warnings;
use Test::More;
use File::Path     qw(make_path);
use File::Basename qw(dirname);
use JSON::PP       qw(decode_json);
use Digest::SHA    qw(hmac_sha256_hex);
use FindBin;
use lib "$FindBin::Bin/../../lib";
use lib "$FindBin::Bin/../../../lib";
use TestHelper qw(repo_root site_tempdir run_processor grant_caps);
use Lazysite::Manager::Extensions qw(action_extension_enable action_extension_disable);
use Lazysite::Extensions::Hooks   qw(validate_hooks cross_problems);
use Lazysite::Auth::Session       ();

$ENV{LAZYSITE_LOG_LEVEL} = 'ERROR';
my $root   = repo_root();
my $SECRET = 'c' x 64;

sub spit { my ( $p, $c ) = @_; open my $fh, '>', $p or die "$p: $!"; print {$fh} $c; close $fh; return }
sub slurp { my ($p) = @_; open my $fh, '<', $p or return ''; local $/; my $s = <$fh>; close $fh; return $s }

sub write_extension {
    my ( $path, $desc ) = @_;
    my $json = JSON::PP->new->canonical->encode($desc);
    $json =~ s/'/'\\''/g;
    spit( $path, "#!/usr/bin/perl\nprint q'$json' if \@ARGV && \$ARGV[0] eq '--describe';\nexit 0;\n" );
    chmod 0755, $path or die $!;
    return;
}

my $N = 0;
my ( $D, $LZ, $M );

# The provider's answers come from lazysite/probe.state, so a case sets them
# without a second fixture: on=0|1|die, stale=1, groups_bad=1.
sub provider_module {
    my ($m) = @_;
    return <<"PM";
package $m;
sub _st { my (\$c) = \@_; my %s; if ( open my \$fh, '<', "\$c->{lazysite_dir}/probe.state" ) { while (<\$fh>) { chomp; \$s{\$1} = \$2 if /\\A(\\w+)=(.*)\\z/ } } return \\%s }
sub on { my \$s = _st(\$_[0]); die "the probe's on died\\n" if ( \$s->{on} // '' ) eq 'die'; return ( \$s->{on} // '1' ) eq '1' ? 1 : 0 }
sub still_valid { my \$s = _st(\$_[0]); return \$s->{stale} ? 'stale' : 'ok' }
sub groups { my ( \$c, \$r ) = \@_; my \$s = _st(\$c); return 'not a list' if \$s->{groups_bad}; return [ \@{ \$r->{groups} || [] } ] }
sub login_option { return { label => 'Sign in with Probe <b>', path => '/probe-signin' } }
sub banner { return '<span class="probe-banner">PROBE-BANNER</span>' }
1;
PM
}

sub fixture {
    my (%o) = @_;
    $M = 'ProbeId' . ++$N;
    $D = site_tempdir();
    my $base = dirname($D);
    system( 'cp', '-r', "$root/starter/.", $D ) == 0 or die 'copy starter';
    $LZ = "$D/lazysite";
    make_path( "$LZ/auth", "$LZ/logs", "$LZ/cache", "$LZ/templates/system", "$base/extensions/probe/lib" );
    spit( "$LZ/lazysite.conf", "site_name: T\n" );
    spit( "$LZ/auth/.secret", "$SECRET\n" );
    chmod 0600, "$LZ/auth/.secret";
    grant_caps( $D, 'boss', 'ui' );       # a secured site
    grant_caps( $D, 'opsuser', 'api' );   # role-opsuser carries a capability
    spit( "$LZ/templates/system/probe-signin.md", "---\ntitle: Probe sign-in\n---\nPROBE-SIGNIN-PAGE\n" );
    spit( "$D/elsewhere.md", "---\ntitle: E\n---\nELSEWHERE\n" );
    my %ip = (
        on           => "${M}::on",
        still_valid  => "${M}::still_valid",
        groups       => "${M}::groups",
        login_option => "${M}::login_option",
        banner       => "${M}::banner",
        renew        => '/cgi-bin/probe.pl?renew=1',
        signin_page  => 'probe-signin',
        ( defined $o{grants} ? ( grants => $o{grants} ) : () ),
    );
    write_extension( "$base/extensions/probe.pl",
        { id => 'probe', name => 'Probe', contract => 1, owns => { hooks => { identity_provider => \%ip } } } );
    spit( "$base/extensions/probe/lib/$M.pm", provider_module($M) );
    no warnings 'once';
    $Lazysite::Manager::Extensions::DOCROOT = $D;
    my $r = action_extension_enable('extensions/probe.pl');
    die 'the fixture provider was not indexed: ' . explain($r) unless $r->{ok} && grep { $_ eq 'probe' } @{ $r->{index}{indexed} || [] };
    set_state();
    return $D;
}

sub set_state { my (%s) = @_; spit( "$LZ/probe.state", join '', map {"$_=$s{$_}\n"} sort keys %s ); return }

sub mint {
    my (%a) = @_;
    local $Lazysite::Auth::Session::LAZYSITE_DIR = $LZ;
    return Lazysite::Auth::Session::mint_provider_session( provider => 'probe', name => 'Pat', %a );
}

sub verify {
    my ( $cookie, %o ) = @_;
    local $ENV{HTTP_COOKIE} = "lazysite_auth=$cookie";
    local $Lazysite::Auth::Session::LAZYSITE_DIR = $LZ;
    return Lazysite::Auth::Session::verify_session_cookie(%o);
}

sub registry { return map { decode_json($_) } grep {length} split /\n/, slurp("$LZ/auth/sessions.jsonl") }

sub signed {
    my ($payload) = @_;
    ( my $e = $payload ) =~ s/([^a-zA-Z0-9_.~:-])/sprintf( '%%%02X', ord $1 )/ge;
    return "$e:" . hmac_sha256_hex( $payload, $SECRET );
}

sub status_of { my ($r) = @_; my ($s) = $r =~ /Status:\s*(\d+)/; return $s // 200 }

# ---------------------------------------------------------------------------
subtest 'the declaration is checked before it is indexed' => sub {
    my %good = ( on => 'P::on', still_valid => 'P::still_valid', groups => 'P::groups' );
    is_deeply( [ validate_hooks( 'probe', { identity_provider => {%good} } ) ], [], 'on, still_valid and groups suffice' );
    my %bad = (
        'a core page'          => { signin_page => 'login' },
        'a page name with /'   => { signin_page => 'a/b' },
        'a renew off the site' => { renew => 'https://evil.example/x?y=1' },
        'a renew with no query' => { renew => '/cgi-bin/probe.pl' },
        'a grants of 2'        => { grants => 2 },
        'an unknown key'       => { secret => 'x' },
    );
    for my $why ( sort keys %bad ) {
        ok( scalar validate_hooks( 'probe', { identity_provider => { %good, %{ $bad{$why} } } } ), "$why: refused" );
    }
    ok( scalar validate_hooks( 'probe', { identity_provider => { on => 'P::on', groups => 'P::groups' } } ),
        'a provider without still_valid: refused' );
    ok( scalar validate_hooks( 'Not_An_Id', { identity_provider => {%good} } ), 'an id a session cannot carry: refused' );
    my %clash = cross_problems( {
            aa => { hooks => { identity_provider => { %good, signin_page => 'x-signin' } } },
            bb => { hooks => { identity_provider => { %good, signin_page => 'x-signin' } } } } );
    like( join( ' ', @{ $clash{bb} || [] } ), qr/sign-in page 'x-signin' is already declared by the extension 'aa'/,
        'two extensions cannot declare one sign-in page: the later is left out' );
    ok( !$clash{aa}, '...and the first keeps it' );
};

# ---------------------------------------------------------------------------
subtest 'core mints and verifies the provider\'s session' => sub {
    fixture();
    my ( $c, $ts, $sid ) = mint( login => 'pat@example.com', groups => [ 'staff', 'wholesale' ] );
    ok( $c, 'a session is minted for the provider' );
    ( my $raw = $c ) =~ s/:[0-9a-f]{64}\z//;
    $raw =~ s/%([0-9A-Fa-f]{2})/chr hex $1/ge;
    is( $raw, "probe=pat\@example.com:$ts:$sid:", 'the cookie: probe=<login>, the issue time, the sid, and no group' );
    my ($rec) = grep { $_->{sid} eq $sid } registry();
    is( $rec->{provider}, 'probe', 'the record names the provider' );
    is( $rec->{user}, 'probe:pat@example.com', '...and the identity' );
    my ( $id, $why ) = verify($c);
    ok( $id, 'it verifies' ) or diag $why;
    is( $id->{user},     'probe:pat@example.com', 'as probe:<login>' );
    is( $id->{provider}, 'probe',                 'naming the provider' );
    is( $id->{groups},   'staff,wholesale',       'with the groups the provider grants' );
    is( ( verify( signed("probe=pat\@example.com:$ts:$sid:") ) )[0]{user}, 'probe:pat@example.com',
        'the same payload signed with the site key is the same session (control)' );
    ( my $forged = $c ) =~ s/:[0-9a-f]{64}\z/':' . hmac_sha256_hex( $raw, 'd' x 64 )/e;
    is( ( verify($forged) )[1], 'signature', 'G-2: signed with any other key it is nothing - only core signs' );
    is( ( verify( signed("probe=pat\@example.com:$ts:0123456789abcdef:") ) )[1], 'no-record',
        'a validly signed cookie for a sid with no record is no session' );
    ok( !mint( login => "bad\x01login", groups => [] ), 'a login with a control byte is refused at the mint' );
};

# ---------------------------------------------------------------------------
subtest 'G-1: off means off' => sub {
    fixture();
    my ($c) = mint( login => 'pat@example.com', groups => ['staff'] );
    set_state( on => 0 );
    is( ( verify($c) )[1], 'probe-off', 'the provider\'s own sign-in off ends its sessions' );
    set_state();
    ok( ( verify($c) )[0], '...and on again restores the (unrevoked) session' );
    action_extension_disable('extensions/probe.pl');
    is( ( verify($c) )[1], 'probe-off', 'the extension disabled: refused' );
    ok( !mint( login => 'kim@example.com', groups => [] ), '...and the provider can mint nothing' );
    action_extension_enable('extensions/probe.pl');
    ok( ( verify($c) )[0], 'enabled again: the session stands' );
    my $conf = slurp("$LZ/lazysite.conf");
    spit( "$LZ/lazysite.conf", "site_name: T\n" );
    is( ( verify($c) )[1], 'probe-off', 'an index left behind for an extension the conf no longer lists verifies nothing' );
    spit( "$LZ/lazysite.conf", $conf );
};

# ---------------------------------------------------------------------------
subtest 'G-3: a group that carries a capability is refused, unless the provider grants' => sub {
    fixture();
    my ($c) = mint( login => 'pat@example.com', groups => [ 'staff', 'role-opsuser', 'role-boss' ] );
    my ($id) = verify($c);
    is( $id->{groups}, 'staff', 'the provider handed three groups and core kept the one that carries nothing' );
    unlike( slurp("$LZ/logs/audit.log"), qr/login-grant/, 'a provider that does not grant writes no grant row' );

    fixture( grants => 1 );
    ($c) = mint( login => 'olga@example.com', groups => [ 'staff', 'role-opsuser' ], ip => '192.0.2.9' );
    ($id) = verify($c);
    is( $id->{groups}, 'staff,role-opsuser', 'a provider that declares grants keeps the capability group (ruling 186)' );
    my ($row) = grep {/login-grant/} split /\n/, slurp("$LZ/logs/audit.log");
    ok( $row, 'and its sign-in is audited' );
    like( $row // '', qr/\| probe:olga\@example\.com \| login-grant \|/, '...naming the identity' );
    like( $row // '', qr/\| probe \| groups granted: staff,role-opsuser\z/, '...the provider and the groups it granted' );
    my ($rec) = grep { $_->{user} eq 'probe:olga@example.com' } registry();
    {
        local $Lazysite::Auth::Session::LAZYSITE_DIR = $LZ;
        ok( Lazysite::Auth::Session::renew_provider_session( provider => 'probe', sid => $rec->{sid}, groups => ['role-opsuser'] ),
            'a renewal' );
    }
    like( slurp("$LZ/logs/audit.log"), qr/\| renew-grant \|.*groups granted: role-opsuser$/m, '...is audited with what it granted' );
};

# ---------------------------------------------------------------------------
subtest 'G-9: a provider that fails signs nobody in; stale is renewed at its path' => sub {
    fixture();
    my ($c) = mint( login => 'pat@example.com', groups => ['staff'] );
    set_state( on => 'die' );
    is( ( verify($c) )[1], 'probe-failed', 'its `on` dies: no session' );
    set_state( groups_bad => 1 );
    is( ( verify($c) )[1], 'probe-failed', 'its `groups` answers something else: no session' );
    set_state( stale => 1 );
    my ( $none, $why, %d ) = verify($c);
    is( $why, 'probe-stale', 'stale: refused' );
    is( $d{renew}, '/cgi-bin/probe.pl?renew=1', '...with the provider\'s renewal path' );
    my ($s) = verify( $c, stale_ok => 1 );
    ok( $s && $s->{stale}, 'with stale_ok it is the identity, stale' );
    is( $s->{groups}, '', '...holding no group' );
    my @line = Lazysite::Auth::Session::session_log_line( undef, 'probe-failed', { user => 'probe:x', provider => 'probe' } );
    is_deeply( [ @line[ 0, 1 ] ], [ 'DEBUG', 'auth: probe session not accepted (probe-failed)' ], 'the log line names the provider' );
};

# ---------------------------------------------------------------------------
subtest 'a record from before X4 stands; another provider\'s record does not' => sub {
    fixture();
    my $now = time;
    my $old = 'a1b2c3d4e5f60718';
    my $other = '0f1e2d3c4b5a6978';
    open my $fh, '>>', "$LZ/auth/sessions.jsonl" or die $!;
    # the record SM1160 wrote (0.15.10 to 0.16.8): the provider's id as a flag
    print {$fh} JSON::PP->new->canonical->encode( { sid => $old, user => 'probe:old@example.com', t => $now, probe => 1,
            checked => $now, name => 'Old', groups => ['staff'], ip => '', ua => '' } ), "\n";
    print {$fh} JSON::PP->new->canonical->encode( { sid => $other, user => 'probe:eve@example.com', t => $now,
            provider => 'other', checked => $now, name => 'Eve', groups => ['staff'] } ), "\n";
    close $fh;
    my ($id) = verify( signed("probe=old\@example.com:$now:$old:") );
    ok( $id, 'a session minted before X4 verifies' );
    is( $id->{groups}, 'staff', '...with its groups' );
    is( ( verify( signed("probe=eve\@example.com:$now:$other:") ) )[1], 'no-record',
        'a record another provider wrote is no session of this one' );
};

# ---------------------------------------------------------------------------
subtest 'the processor: the sign-in page, the login option, the banner, maintenance' => sub {
    # off first, on a site that has rendered nothing yet (a render is cached)
    fixture();
    set_state( on => 0 );
    is( status_of( run_processor( $D, '/probe-signin' ) ), 404, 'its own sign-in off: the page is not found' );
    unlike( run_processor( $D, '/login' ), qr/login-probe|PROBE-BANNER/, '...and /login offers nothing of it' );

    fixture();
    my $page = run_processor( $D, '/probe-signin' );
    is( status_of($page), 200, 'the provider\'s sign-in page is a system page while it is on' );
    like( $page, qr/PROBE-SIGNIN-PAGE/, '...from the engine\'s templates' );
    my $login = run_processor( $D, '/login', QUERY_STRING => 'next=/members' );
    like( $login, qr{<p class="login-probe" data-ls-auth-in><a href="/probe-signin\?next=%2Fmembers">Sign in with Probe &lt;b&gt;</a></p>},
        '/login offers the provider, its label escaped, carrying next' );
    like( $login, qr{<span class="probe-banner">PROBE-BANNER</span>}, 'the fallback chrome carries signin_banner' );

    open my $cf, '>>', "$LZ/lazysite.conf" or die $!;
    print {$cf} "maintenance: on\n";
    close $cf;
    like( run_processor( $D, '/elsewhere' ), qr/Status: 302/, 'in maintenance a page is sent away' );
    is( status_of( run_processor( $D, '/probe-signin' ) ), 200, '...and the provider\'s sign-in page stays reachable' );

    action_extension_disable('extensions/probe.pl');
    is( status_of( run_processor( $D, '/probe-signin' ) ), 302, 'the extension off: its page is a page like any other, sent away' );
    unlike( run_processor( $D, '/login' ), qr/login-probe|PROBE-BANNER/, '...and /login offers nothing of it' );
};

done_testing();
