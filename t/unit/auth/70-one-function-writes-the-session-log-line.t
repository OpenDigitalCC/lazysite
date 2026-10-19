#!/usr/bin/perl
# SM1181 S3 (T11): THE LOG LINE FOR A SESSION DECISION IS ONE FUNCTION'S.
#
# The auth wrapper's handle_request logged each outcome of the verifier at the
# level it has always had (SM1099: the ordinary cases DEBUG, a cookie that should
# have worked and did not WARN). From S3 the pool's front door decides a signed-in
# page in its worker, so it must leave the same evidence; both now take the line
# from Lazysite::Auth::Session::session_log_line. This pins the table to the lines
# the wrapper wrote before the move (claude/n677, 8a8fdeecb), so the move changed
# none of them, and holds that no cookie value is ever a field.
use strict;
use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/../../lib";
use lib "$FindBin::Bin/../../../lib";
use TestHelper qw(repo_root);
use Lazysite::Auth::Session ();

sub line { return [ Lazysite::Auth::Session::session_log_line(@_) ] }

my $cookie = { user => 'alice', groups => [ 'staff', 'team' ], source => 'cookie', sid => 'abc' };
my $proxy  = { user => 'pat',   groups => [],                  source => 'proxy' };

is_deeply( line( $cookie, undef, {} ), [ 'DEBUG', 'auth: cookie valid', user => 'alice', groups => 'staff,team' ],
    'a valid session: DEBUG, naming the account and its fresh groups' );
is_deeply( line( $proxy, undef, {}, cookie_sent => 1 ), [ 'DEBUG', 'auth: proxy identity wins, cookie ignored', proxy_user => 'pat' ],
    'a proxy user over a cookie: DEBUG' );
is_deeply( line( $proxy, undef, {}, cookie_sent => 0 ), [], 'a proxy user and no cookie: nothing' );

my %WHY = (
    'no-cookie'      => [ 'DEBUG', 'auth: no cookie' ],
    'malformed'      => [ 'WARN',  'auth: cookie malformed' ],
    'signature'      => [ 'WARN',  'auth: signature mismatch' ],
    'expired'        => [ 'WARN',  'auth: cookie expired or malformed ts', ts => 12 ],
    'no-account'     => [ 'WARN',  'auth: account does not exist', user => 'erin' ],
    'disabled'       => [ 'WARN',  'auth: account disabled', user => 'erin' ],
    'cannot-tell'    => [ 'WARN',  'auth: cannot tell - session refused until the store is repaired', user => 'erin', store => 'lazysite/auth/revoked.json' ],
    'odoo-off'       => [ 'DEBUG', 'auth: odoo session not accepted (odoo-off)', user => 'erin' ],
    'odoo-unsecured' => [ 'DEBUG', 'auth: odoo session not accepted (odoo-unsecured)', user => 'erin' ],
    'odoo-stale'     => [ 'DEBUG', 'auth: odoo session not accepted (odoo-stale)', user => 'erin' ],
    'no-record'      => [ 'DEBUG', 'auth: odoo session not accepted (no-record)', user => 'erin' ],
    'revoked'        => [ 'WARN',  'auth: session revoked', user => 'erin' ],
);
my %detail = ( user => 'erin', ts => 12, store => 'lazysite/auth/revoked.json', cookie => 'lazysite_auth=SECRETVALUE' );
for my $why ( sort keys %WHY ) {
    my $got = line( undef, $why, \%detail );
    my %want_f = @{ $WHY{$why} }[ 2 .. $#{ $WHY{$why} } ];
    my %got_f  = @{$got}[ 2 .. $#$got ];
    is_deeply( [ @{$got}[ 0, 1 ], \%got_f ], [ @{ $WHY{$why} }[ 0, 1 ], \%want_f ], "$why: the wrapper's line, at its level" );
    unlike( join( ' ', @$got ), qr/SECRETVALUE/, "$why: no cookie value is a field" );
}
is_deeply( line( undef, 'expired', {} ), [ 'WARN', 'auth: cookie expired or malformed ts', ts => 'undef' ],
    'an expiry with no ts names it undef, as before' );
is_deeply( line( undef, 'something-new', {} ), [], 'an outcome with no line logs nothing' );

# Both callers use it, and the wrapper keeps no copy of the table.
my $root = repo_root();
for my $f (qw(lazysite-auth.pl lazysite-processor/front-door.pm)) {
    open my $fh, '<', "$root/$f" or die "$f: $!";
    my $src = do { local $/; <$fh> };
    like( $src, qr/Lazysite::Auth::Session::session_log_line\(\s*\$ident,\s*\$why,\s*\\%detail/, "$f logs through it" );
    unlike( $src, qr/'auth: (?:signature mismatch|account disabled|session revoked)'/, "$f holds no copy of the lines" );
}

done_testing();
