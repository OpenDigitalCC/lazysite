#!/usr/bin/perl
# SM633: the switches that decide whether anyone can reach the instance at all
# are their own capability.
#
# `manage_config` governed both the site's title and cache lifetime AND the five
# service killswitches - webdav, mcp, oauth, control_api, token_exchange - under
# a capability whose own title says "SAFE site configuration". Those are not the
# same size of decision.
#
# SM612 closed the sharpest edge: a token can no longer switch off the manager
# surface that would revoke it. That was a fix at the KEY level. This is the
# LOCK being the right shape - an operator can hand a partner the ability to
# tune caching without handing it the ability to turn WebDAV off for everyone.
#
# WHAT SWITCHING ONE OFF ACTUALLY DOES is why it deserves its own grant: it does
# not narrow a grant, it stops the surface answering for EVERYONE, including
# partners and agents already connected.
use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use FindBin;
use lib "$FindBin::Bin/../../lib";
use lib "$FindBin::Bin/../../../lib";
use Lazysite::Capabilities   ();
use Lazysite::Auth::Settings ();
use JSON::PP qw(encode_json decode_json);
use MIME::Base64 qw(encode_base64);
use IPC::Open2;
use IPC::Open3;
use Symbol qw(gensym);
use TestHelper qw(grant_caps);

my $root  = "$FindBin::Bin/../../..";
my $tool  = "$root/tools/lazysite-users.pl";
my $mapil = "$root/lazysite-manager-api.pl";
plan skip_all => "no $tool" unless -f $tool;

# Same harness shape as t/unit/manager/17 - the two files exercise the same
# door, and section 2b below is the half of THIS rule that 17 cannot carry.
sub uapi {
    my ( $d, $p ) = @_;
    my ( $o, $i );
    my $pid = open2( $o, $i, $^X, $tool, '--api', '--docroot', $d );
    print {$i} encode_json($p);
    close $i;
    my $out = do { local $/; <$o> };
    close $o;
    waitpid $pid, 0;
    return eval { decode_json($out) } // {};
}

sub mapi {
    my ( $d, %o ) = @_;
    my $body = delete $o{body};
    local %ENV = %ENV;
    $ENV{DOCUMENT_ROOT}  = $d;
    $ENV{REQUEST_METHOD} = $o{REQUEST_METHOD} || 'GET';
    $ENV{CONTENT_LENGTH} = defined $body ? length($body) : 0;
    delete $ENV{HTTP_X_REMOTE_USER};
    $ENV{$_} = $o{$_} for grep { defined $o{$_} } keys %o;
    my ( $w, $r );
    my $e   = gensym;
    my $pid = open3( $w, $r, $e, $^X, $mapil );
    print {$w} ( defined $body ? $body : '' );
    close $w;
    my $out = do { local $/; <$r> };
    close $r;
    waitpid $pid, 0;
    my ($jb) = $out =~ /\r?\n\r?\n(.*)/s;
    return eval { decode_json( $jb // '' ) } // { _raw => $out };
}
sub basic { return 'Basic ' . encode_base64( "$_[0]:$_[1]", '' ) }

sub conf {
    open my $f, '<', "$_[0]/lazysite/lazysite.conf" or die $!;
    local $/;
    return <$f>;
}

# --- 1. the capability exists and says what it is ---------------------------
{
    my $caps = Lazysite::Capabilities::describe()->{capabilities} || {};
    ok( $caps->{manage_services}, 'manage_services is declared' )
        or do { done_testing(); exit };
    like( $caps->{manage_services}{grants}, qr/EVERYONE|everyone/,
        'and says switching one off stops the surface for everyone, not just '
            . 'for the account that flipped it' );
    like( $caps->{manage_services}{grants}, qr/manager UI is unaffected/i,
        'and that the manager is not among them - the recovery surface stays' );

    # manage_config must stop claiming them, or the split is only half made and
    # the sentence an operator reads is the stale half.
    # Asserted as a DISCLAIMER, not as an absence. The first version forbade the
    # phrase "whether ... answer at all" - and the new sentence uses those very
    # words to point AWAY from itself ("the switches that decide whether the
    # remote surfaces answer at all are `manage_services`"). Forbidding the
    # vocabulary would have forced the sentence to be vaguer to pass, which is
    # the opposite of what SM427 is for.
    like( $caps->{manage_config}{grants}, qr/held separately|are `manage_services`/,
        'manage_config disclaims the service switches rather than claiming them' );
    like( $caps->{manage_config}{grants}, qr/ordinary site settings/,
        'and says what it does cover' );
    like( $caps->{manage_config}{grants}, qr/manage_services/,
        'naming the capability that holds the rest' );

    ok( ( grep { $_ eq 'manage_services' } Lazysite::Auth::Settings::CAP_KEYS() ),
        'it is a real capability key, so groups can carry it' )
        if Lazysite::Auth::Settings->can('CAP_KEYS');
}

# --- 2. the two lists cannot drift ------------------------------------------
# The keys the check gates on, and the keys that exist. A switch added to the
# allowlist without being named a service key would quietly fall back to
# manage_config - which is the defect this closes, re-made.
{
    my $api = do { open my $fh, '<', "$root/lazysite-manager-api.pl" or die $!; local $/; <$fh> };
    my ($svc) = $api =~ /my %SERVICE_KEY = map \{ \$_ => 1 \}\s*\n\s*qw\((.*?)\)/s;
    ok( $svc, 'the service keys are named in one place' );
    my @svc = sort split ' ', ( $svc // '' );
    is_deeply( \@svc,
        [qw(control_api_enabled mcp_enabled oauth_enabled token_exchange_enabled webdav_enabled)],
        'all five switches, and only those' );

    my ($allow) = $api =~ /my %allow = map \{ \$_ => 1 \}\s*\n\s*qw\((.*?)\)/s;
    my %allowed = map  { $_ => 1 } split ' ', ( $allow // '' );
    my @orphan  = grep { !$allowed{$_} } @svc;
    is_deeply( \@orphan, [],
        'every service key is settable at all - one that is not would make the '
            . 'capability gate unreachable and look like a working rule' );

}

# --- 2b. THE LOCK, NOT THE TEXT ---------------------------------------------
# Everything above reads source and declarations. None of it proves the server
# refuses anything. This section mints two real tokens against a real docroot
# and asks the running API - because a config-text match is not behaviour.
#
# The negative is proved with a credential that genuinely LACKS manage_services
# and holds everything else the call needs, so a refusal cannot be the token
# merely being unable to reach config-set at all. The positive uses the same
# grant plus the one capability, so the difference between them IS the rule.
{
    my $d = tempdir( CLEANUP => 1 );
    make_path("$d/lazysite/auth");
    open my $cf, '>', "$d/lazysite/lazysite.conf" or die $!;
    print {$cf} "site_name: My Site\ncontrol_api_enabled: true\n";
    close $cf;

    uapi( $d, { action => 'add', username => 'weak',   password => 'x' } );
    uapi( $d, { action => 'add', username => 'strong', password => 'x' } );
    grant_caps( $d, 'weak',   'manage_config', 'api' );
    grant_caps( $d, 'strong', 'manage_config', 'api', 'manage_services' );
    my $wtok = uapi( $d, { action => 'token', username => 'weak' } )->{token};
    my $stok = uapi( $d, { action => 'token', username => 'strong' } )->{token};
    ok( $wtok && $stok, 'minted both tokens' ) or do { done_testing(); exit };

    # The weak token must be able to do the ORDINARY job, or its refusal below
    # proves nothing about the capability - only that the token was inert.
    my $ord = mapi( $d, REQUEST_METHOD => 'POST', QUERY_STRING => 'action=config-set',
        HTTP_AUTHORIZATION => basic( 'weak', $wtok ),
        body => encode_json( { key => 'site_name', value => 'Renamed' } ) );
    ok( $ord->{ok}, 'manage_config alone still sets an ordinary site setting' );

    # ALL FIVE, not a sample - a switch left ungated is the whole defect.
    for my $k (qw(webdav_enabled mcp_enabled oauth_enabled control_api_enabled
        token_exchange_enabled))
    {
        my $r = mapi( $d, REQUEST_METHOD => 'POST', QUERY_STRING => 'action=config-set',
            HTTP_AUTHORIZATION => basic( 'weak', $wtok ),
            body => encode_json( { key => $k, value => 'disabled' } ) );
        ok( !$r->{ok}, "manage_config alone cannot set '$k'" );
        like( $r->{error} // '', qr/manage_services/,
            "the refusal for '$k' names the capability that is missing" );
        # Absence would be the wrong property: control_api_enabled is already
        # in this fixture (the token API needs it on), and a switch the request
        # never mentions is absent whether the lock works or not. What must
        # hold is that the REQUESTED value did not land.
        unlike( conf($d), qr/^\Q$k\E:\s*disabled/m,
            "'$k' kept its prior value - the refusal is the lock, not just a message" );
    }

    my $ok = mapi( $d, REQUEST_METHOD => 'POST', QUERY_STRING => 'action=config-set',
        HTTP_AUTHORIZATION => basic( 'strong', $stok ),
        body => encode_json( { key => 'mcp_enabled', value => 'disabled' } ) );
    ok( $ok->{ok}, 'the SAME call succeeds once manage_services is held' )
        or diag( $ok->{error} // 'no error' );
    like( conf($d), qr/^mcp_enabled:\s*disabled/m,
        'and the switch actually reached lazysite.conf' );
}

# --- 3. a fresh site gives the admin group the capability -------------------
sub fresh {
    my $d = tempdir( CLEANUP => 1 );
    make_path("$d/lazysite");
    open my $c, '>', "$d/lazysite/lazysite.conf" or die $!;
    print {$c} "manager_groups: sysops\n";
    close $c;
    system( $^X, $tool, '--docroot', $d, 'setup-sysop', '--user', 'sjm' ) == 0 or return undef;
    return $d;
}
sub settings {
    my ($d) = @_;
    require JSON::PP;
    return JSON::PP::decode_json(
        do { open my $fh, '<', "$d/lazysite/auth/groups-settings.json" or die $!; local $/; <$fh> } );
}

my $d = fresh() or plan skip_all => 'setup-sysop failed';
{
    my $gs = settings($d);
    ok( $gs->{'sysops'}{manage_services},
        'a fresh install gives the admin group the new capability - it holds '
            . 'everything else, and withholding this one would break a working '
            . 'site on nothing but a version change' );
    ok( ( grep { $_ eq 'manage_services' } @{ $gs->{'sysops'}{grantable} || [] } ),
        'and the authority to confer it (SM630)' );
}

# --- 4. AN EXISTING SITE IS ASKED, not silently changed ---------------------
# The migration question, and the one that would be easy to get wrong in either
# direction: granting it silently widens a live grant, removing it silently
# narrows one. The project already has the answer - SM496's pending decision.
{
    my $gs = settings($d);
    delete $gs->{'sysops'}{manage_services};    # a site upgraded from before
    open my $fh, '>', "$d/lazysite/auth/groups-settings.json" or die $!;
    require JSON::PP;
    print {$fh} JSON::PP->new->encode($gs);
    close $fh;

    # --api reads its request from STDIN. An earlier draft opened it with
    # nothing to send and never closed the input, and the test hung for two
    # minutes before being killed - a reminder that a pipe-open with no writer
    # is a wait, not an error.
    my $view = `printf '%s' '{"action":"group-settings-get"}' | $^X \Q$tool\E --docroot \Q$d\E --api 2>/dev/null`;
    my $d2 = eval { JSON::PP::decode_json($view) };
    ok( $d2 && $d2->{groups}, 'the settings view loads' ) or do { done_testing(); exit };
    my $pending = $d2->{groups}{'sysops'}{pending} || [];
    ok( ( grep { $_ eq 'manage_services' } @$pending ),
        'an upgraded site OFFERS the decision rather than making it - granting '
            . 'silently would widen a live grant, removing silently would narrow '
            . 'one, and both are decisions belonging to the operator' );
}

done_testing();
