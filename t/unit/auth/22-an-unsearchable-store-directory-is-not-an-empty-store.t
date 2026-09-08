#!/usr/bin/perl
# SM770: a stat the process may not make fails exactly as an open it may not
# make - so `return {} unless -f $path` in front of a store read turned a
# permissions fault into absence BEFORE the open could report it.
#
# THE CASE THE OLD GUARDS HID is not an unreadable file - SM766 already covers
# that - but an unreadable DIRECTORY. Take the search bit off lazysite/auth and
# every `-f` inside it answers false, whatever the files say: the account store
# reads as "no accounts", the group store as "no groups", and a capability
# lookup as "this account holds nothing". Every one of those is a fact about
# the site that is not true, and before this none of them was even logged.
#
# The files here are readable throughout. Only the directory changes.
use strict;
use warnings;
use Test::More;
use File::Path qw(make_path);
use FindBin;
use lib "$FindBin::Bin/../../../lib", "$FindBin::Bin/../../lib";
use TestHelper qw(site_tempdir);

use Lazysite::Auth::Settings;
use Lazysite::Auth::Acl;
use Lazysite::Auth::Session;

plan skip_all => 'root searches every directory; this needs an unprivileged user' if $> == 0;

my $d    = site_tempdir();
my $auth = "$d/lazysite/auth";
make_path($auth);
sub put { my ( $p, $c ) = @_; open my $fh, '>', $p or die "$p: $!"; print {$fh} $c; close $fh }

put( "$auth/users",                "alice:x\n" );
put( "$auth/groups",               "editors: alice\n" );
put( "$auth/groups-settings.json", '{"editors":{"manage_content":1}}' );
put( "$auth/user-settings.json",   '{"alice":{"display_name":"Alice"}}' );
put( "$auth/acls.json",            '{"/private":{"read":["alice"]}}' );

$Lazysite::Auth::Settings::AUTH_DIR    = $auth;
$Lazysite::Auth::Acl::DOCROOT          = $d;
$Lazysite::Auth::Session::LAZYSITE_DIR = "$d/lazysite";

# What the readers say when everything is readable - the baseline every
# assertion below is measured against.
my %caps_before = %{ Lazysite::Auth::Settings::caps_for('alice') };
ok( $caps_before{manage_content}, 'baseline: alice holds manage_content' );
is( Lazysite::Auth::Settings::display_name_for('alice'), 'Alice', 'baseline: and has a display name' );

my @log;
sub with_log {
    my ($code) = @_;
    @log = ();
    no warnings 'redefine';
    # cannot_read logs from Util; a caller that decides what to DO about the
    # fault logs from its own package, having imported the same sub.
    local *Lazysite::Util::log_event          = sub { push @log, [@_] };
    local *Lazysite::Auth::Session::log_event = sub { push @log, [@_] };
    my @r = $code->();
    return @r;
}
sub warned_about {
    my ($what) = @_;
    return scalar grep { $_->[0] eq 'WARN' && $_->[2] =~ /cannot read \Q$what\E/ } @log;
}

subtest 'the directory cannot be searched: every reader says so' => sub {
    chmod 0000, $auth;
    my $can = !-r "$auth/users";    # confirm the fixture actually bites
    ok( $can, 'the fixture holds: a file inside is unreadable while the file itself is fine' )
        or do { chmod 0755, $auth; plan skip_all => 'this filesystem ignores the directory mode' };

    with_log( sub { Lazysite::Auth::Settings::read_settings() } );
    ok( warned_about('user-settings.json'), 'read_settings WARNs rather than returning {} in silence' )
        or diag explain \@log;

    with_log( sub { Lazysite::Auth::Settings::read_group_settings() } );
    ok( warned_about('groups-settings.json'), 'read_group_settings WARNs' ) or diag explain \@log;

    with_log( sub { Lazysite::Auth::Settings::_groups_membership() } );
    ok( warned_about('groups'), 'the group membership reader WARNs' ) or diag explain \@log;

    with_log( sub { Lazysite::Auth::Acl::load_acls() } );
    ok( warned_about('acls'), 'load_acls WARNs' ) or diag explain \@log;

    chmod 0755, $auth;
};

subtest 'and the log names the file, the error and the unix user' => sub {
    chmod 0000, $auth;
    with_log( sub { Lazysite::Auth::Settings::read_settings() } );
    chmod 0755, $auth;

    my ($row) = grep { $_->[0] eq 'WARN' && $_->[2] =~ /cannot read/ } @log;
    ok( $row, 'a WARN was logged' ) or return;
    my %f = @{$row}[ 3 .. $#{$row} ];
    like( $f{file},      qr/user-settings\.json\z/, 'the file' );
    like( $f{error},     qr/\S/,                    'the error' );
    like( $f{unix_user}, qr/\S/, 'and the unix user - the fact that makes it actionable' );
};

subtest 'once the directory is searchable again the answers come back' => sub {
    is_deeply( { %{ Lazysite::Auth::Settings::caps_for('alice') } }, {%caps_before},
        'the capabilities are unchanged - the fault was never a fact about the account' );
    is( Lazysite::Auth::Settings::display_name_for('alice'), 'Alice', 'and the display name is back' );
};

# SM770: session_revoked used to answer 0 for a file it could not open AND for
# one that was not there, and its own WARN could not tell them apart because
# the `-f` guard had already returned. No revocations file is the ordinary
# state of a site that has never revoked anything; one that will not open is a
# fault, and "NO session is revoked" is the dangerous direction to fail in.
subtest 'an unreadable revocations file is not an empty one' => sub {
    put( "$auth/revoked.json", '{"alice":{"1":1}}' );
    chmod 0000, "$auth/revoked.json";
    with_log( sub { Lazysite::Auth::Session::session_revoked( 'alice', 1, 'sid' ) } );
    ok( warned_about('session'), 'the reader WARNs through cannot_read' ) or diag explain \@log;
    ok( ( grep { $_->[0] eq 'WARN' && $_->[2] =~ /revoked\.json unreadable/ } @log ),
        'and the caller says what it is doing about it' ) or diag explain \@log;
    chmod 0644, "$auth/revoked.json";

    unlink "$auth/revoked.json";
    with_log( sub { Lazysite::Auth::Session::session_revoked( 'alice', 1, 'sid' ) } );
    is( scalar( grep { $_->[0] eq 'WARN' } @log ), 0,
        'while no revocations file at all is silent - the ordinary state' ) or diag explain \@log;
};

subtest 'an absent store still says nothing - absence is ordinary' => sub {
    my $empty = site_tempdir();
    make_path("$empty/lazysite/auth");
    local $Lazysite::Auth::Settings::AUTH_DIR = "$empty/lazysite/auth";
    with_log( sub { Lazysite::Auth::Settings::read_settings() } );
    is( scalar( grep { $_->[0] eq 'WARN' } @log ), 0, 'no WARN for a store that is simply not there yet' )
        or diag explain \@log;
};

END { chmod 0755, $auth if defined $auth } # File::Temp cannot clean a directory it cannot enter

done_testing;
