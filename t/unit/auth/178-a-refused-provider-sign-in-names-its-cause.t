#!/usr/bin/perl
# SM1459: A REFUSED PROVIDER SIGN-IN NAMES ITS CAUSE.
#
# Lazysite::Auth::Session::mint_provider_session refuses for six reasons, and until this
# change none said which: the caller (the Odoo extension) answered "the auth secret is
# missing or the session registry cannot be written" for every one, and the log was
# silent. A site whose extensions index was built by an older engine lost its Odoo
# sign-in that way, with a healthy secret and registry.
#
# Each cause below gives its own reason (for the caller's page: the cause class and what
# to do, no path or secret) and one WARN line in the event log (the provider, the path
# or the remedy). The Odoo extension's 503 carries the reason, not its fixed text.
#
# Sabotage (each run by hand, each fails here): restore the old `or return ()` forms in
# mint_provider_session; give the Odoo refusal its old fixed sentence back.
use strict;
use warnings;
use Test::More;
use File::Path qw(make_path remove_tree);
use JSON::PP   qw(encode_json);
use FindBin;
use lib "$FindBin::Bin/../../lib";
use lib "$FindBin::Bin/../../../lib";
use TestHelper qw(site_tempdir);
use Lazysite::Auth::Session ();

$ENV{LAZYSITE_LOG_LEVEL} = 'ERROR';    # the unit's own stderr stays quiet; the sub below takes the lines

my $D  = site_tempdir();
my $LZ = "$D/lazysite";
make_path("$LZ/auth");

sub spit { my ( $p, $c ) = @_; open my $fh, '>', $p or die "$p: $!"; print {$fh} $c; close $fh; return }

my $HOOK = { on => 'P::on', still_valid => 'P::still_valid', groups => 'P::groups' };

sub set_index {
    my (%o) = @_;
    my $e = { key => 'extensions/probe.pl', hooks => ( $o{hooks} // { identity_provider => $HOOK } ) };
    $e->{requires_keys} = $o{requires_keys} if $o{requires_keys};
    spit( "$LZ/extensions.index.json", encode_json( { format => 1, extensions => ( $o{none} ? {} : { probe => $e } ) } ) );
    spit( "$LZ/lazysite.conf", "site_name: T\nextensions:\n" . join( '', map {"  - $_\n"} @{ $o{on} // ['extensions/probe.pl'] } ) );
    return;
}

my @log;

# ( $cookie_list_count, $why, @log ) for one mint
sub mint {
    my (%a) = @_;
    @log = ();
    no warnings 'once';
    local $Lazysite::Auth::Session::LAZYSITE_DIR = $LZ;
    local *Lazysite::Auth::Session::log_event = sub { push @log, [@_] };
    my $why;
    my @r = Lazysite::Auth::Session::mint_provider_session( provider => 'probe', login => 'pat@example.com', name => 'Pat',
        refusal => \$why, %a );
    return ( \@r, $why );
}

sub line_for {
    my ($re) = @_;
    return ( grep { $_->[0] eq 'WARN' && $_->[2] =~ /\Qa provider sign-in was refused\E/ && join( ' ', @$_ ) =~ $re } @log )[0];
}

# ---- the good case: nothing refused, nothing logged ----
set_index();
spit( "$LZ/auth/.secret", 'a' x 64 );
{
    my ( $r, $why ) = mint();
    is( scalar @$r, 3, 'a usable provider, secret and registry: a session is minted' );
    is( $why, '', '...and no reason is given' );
    is( scalar @log, 0, '...and nothing is logged' );
}

my %reason;

# ---- 1. the provider is not in the index ----
subtest 'not in the index (a site whose index is missing, or lists no such extension)' => sub {
    set_index( none => 1 );
    my ( $r, $why ) = mint();
    is( scalar @$r, 0, 'refused' );
    like( $why, qr/not in the extensions index/, 'the reason says the provider is not indexed' );
    like( $why, qr/stale or the extension is off/, '...that the index is stale or the extension is off' );
    like( $why, qr/rebuild the extensions index or switch the extension on/, '...and what to do' );
    unlike( $why, qr/\Q$D\E|secret|\.jsonl/, '...with no path and no secret in it' );
    my $l = line_for(qr/provider probe/) or return fail('one WARN line names the provider');
    like( join( ' ', @$l ), qr/not-indexed/, 'the log line names the class' );
    like( join( ' ', @$l ), qr/rebuild_hook_index_main/, '...and the command an operator runs' );
    is( scalar @log, 1, 'exactly one line for the refusal' );
    $reason{notindexed} = $why;
};

# ---- 1b. the index is older than the engine: the entry has no sign-in declaration ----
subtest 'an index built by an older engine' => sub {
    set_index( hooks => { endpoints => [] } );
    my ( $r, $why ) = mint();
    is( scalar @$r, 0, 'refused' );
    like( $why, qr/older engine/, 'the reason says the index is from an older engine' );
    like( $why, qr/rebuild the extensions index/, '...and to rebuild it' );
    my $l = line_for(qr/stale-index/) or return fail('a line names the class');
    like( join( ' ', @$l ), qr/rebuild_hook_index_main/, '...with the command' );
    $reason{stale} = $why;
};

# ---- 1c. the extension is switched off, or one it requires ----
subtest 'the extension, or one it requires, is off' => sub {
    set_index( on => [] );
    my ( $r, $why ) = mint();
    is( scalar @$r, 0, 'refused with the extension off' );
    like( $why, qr/switched off/, 'the reason says it is switched off' );
    ok( line_for(qr/provider probe.*\(off\)|\(off\).*provider probe/), 'one line names the provider and the class' );
    unlike( join( ' ', map { join ' ', @$_ } @log ), qr/rebuild_hook_index_main/, '...and does not send the operator to rebuild' );
    $reason{off} = $why;

    set_index( requires_keys => ['extensions/other.pl'] );
    ( $r, $why ) = mint();
    is( scalar @$r, 0, 'refused with a required extension off' );
    like( $why, qr/requires is switched off/, 'the reason says so' );
    $reason{requires} = $why;
};

# ---- 2. the login ----
subtest 'the login cannot be a session\'s' => sub {
    set_index();
    for my $bad ( [ 'an empty login', '' ], [ 'a control character', "a\nb" ], [ 'too long', 'x' x 300 ], [ 'a pipe', 'a|b' ] ) {
        my ( $r, $why ) = mint( login => $bad->[1] );
        is( scalar @$r, 0, "$bad->[0]: refused" );
        like( $why, qr/usable login/, '...the reason names the login' );
        my $l = line_for(qr/provider probe/) or return fail("$bad->[0]: a line names the provider");
        like( $l->[2], qr/login that cannot be a session/, '...and the log line says so' );
        unlike( join( ' ', @$l ), qr/x{20}/, 'the login itself is not logged' );
    }
    $reason{login} = ( mint( login => '' ) )[1];
};

# ---- 3. the auth secret ----
subtest 'the auth secret' => sub {
    unlink "$LZ/auth/.secret";
    my ( $r, $why ) = mint();
    is( scalar @$r, 0, 'a missing secret: refused' );
    like( $why, qr/no auth secret/, 'the reason says there is none' );
    unlike( $why, qr/\Q$D\E/, '...and names no path' );
    my $l = line_for(qr/does not exist/) or return fail('a missing secret leaves a line (ENOENT was silent)');
    like( join( ' ', @$l ), qr{file \Q$LZ\E/auth/\.secret}, '...naming the path' );
    like( join( ' ', @$l ), qr/provider probe/, '...and the provider' );
    $reason{nosecret} = $why;

    spit( "$LZ/auth/.secret", '' );
    ( $r, $why ) = mint();
    is( scalar @$r, 0, 'an empty secret: refused' );
    like( $why, qr/empty or unreadable/, 'the reason says it is empty or unreadable' );
    ok( line_for(qr/exists and is empty or cannot be read/), '...and a line says so' );
    $reason{emptysecret} = $why;
    spit( "$LZ/auth/.secret", 'a' x 64 );
};

# ---- 4. the registry ----
subtest 'the session registry' => sub {
    unlink "$LZ/auth/sessions.jsonl";
    mkdir "$LZ/auth/sessions.jsonl" or die $!;    # a directory: the append cannot open it, root or not
    my ( $r, $why ) = mint();
    is( scalar @$r, 0, 'a registry that cannot be written: refused' );
    like( $why, qr/session registry cannot be written/, 'the reason says so' );
    unlike( $why, qr/\Q$D\E/, '...and names no path' );
    my $l = line_for(qr/registry cannot be written/) or return fail('a line names the registry');
    like( join( ' ', @$l ), qr{file \Q$LZ\E/auth/sessions\.jsonl}, '...naming the path' );
    like( join( ' ', @$l ), qr/error \S/, '...and the system error' );
    $reason{registry} = $why;
    rmdir "$LZ/auth/sessions.jsonl";
};

# ---- the causes are told apart ----
my %seen;
$seen{$_}++ for values %reason;
is( scalar( keys %seen ), scalar( keys %reason ), 'every cause gives a reason of its own' )
    or diag( join "\n", map {"$_: $reason{$_}"} sort keys %reason );

# ---- a caller that passes no `refusal` still gets the empty list and the log line ----
subtest 'a caller that asks for no reason' => sub {
    set_index( none => 1 );
    @log = ();
    no warnings 'once';
    local $Lazysite::Auth::Session::LAZYSITE_DIR = $LZ;
    local *Lazysite::Auth::Session::log_event = sub { push @log, [@_] };
    my @r = Lazysite::Auth::Session::mint_provider_session( provider => 'probe', login => 'pat' );
    is( scalar @r, 0, 'still the empty list' );
    is( scalar @log, 1, '...and still the one line' );
};

done_testing;
