#!/usr/bin/perl
# SM860: a row written through the data endpoint records the account that wrote
# it.
#
# `created_by` is stamped by Tables::_stamp from $opt{actor}, which
# Manager::Data::action_data_row_save takes from the package global $auth_user -
# declared `our $auth_user = '';  # set by each surface`. Two surfaces set it
# (lazysite-manager-api.pl, lazysite-mcp.pl, both marked SM468) and
# lazysite-data.pl did not, so it passed the empty default and the column was
# written NULL.
#
# WHY THAT IS WORSE THAN A BLANK FIELD, and why this test asserts both
# directions: _stamp's own contract is that an empty created_by means "the
# writer was not a signed-in account (a public form): an absence, never a
# guess". Absence is load-bearing - it means anonymous. So a signed-in
# account's row arriving empty does not read as missing data, it reads as a
# positive claim that nobody was signed in. A fix that filled the column in
# every case would destroy the distinction instead of restoring it, which is
# why the anonymous case is asserted too.
use strict;
use warnings;
use Test::More;
use File::Path qw(make_path);
use JSON::PP;
use FindBin;
use lib "$FindBin::Bin/../lib";

BEGIN {
    eval { require DBI; require DBD::SQLite; require YAML::PP; 1 }
        or plan skip_all => 'DBI/DBD::SQLite/YAML::PP not available';
}
use TestHelper              qw(repo_root env_passthrough site_tempdir);
use Lazysite::Data::Tables  qw(apply_schema read_rows);
use Lazysite::Auth::Session ();

my $root = repo_root();
# site_tempdir, not a bare tempdir: t/lint/118 caps how many tests hand the
# engine a raw temporary directory as a docroot, and it sits one level down so
# sibling writes go with it.
my $docroot = site_tempdir();
make_path( "$docroot/lazysite/db/tables", "$docroot/lazysite/auth" );

open my $cf, '>', "$docroot/lazysite/lazysite.conf" or die $!;
print {$cf} "site_name: T\nplugins:\n  - plugins/data.pl\n";
close $cf;

# timestamps: true is what supplies created_by at all.
open my $df, '>', "$docroot/lazysite/db/tables/notes.yaml" or die $!;
print {$df} "public: true\nkey: code\ntimestamps: true\n"
    . "fields:\n  code:\n    type: text\n    required: true\n"
    . "  body:\n    type: text\n";
close $df;
apply_schema( $docroot, 'notes' );

my $users = "$root/tools/lazysite-users.pl";
qx($^X \Q$users\E --docroot \Q$docroot\E setup-sysop --user sjm pw123456789 2>/dev/null);
qx($^X \Q$users\E --docroot \Q$docroot\E add writer pw123456789 2>/dev/null);
qx($^X \Q$users\E --docroot \Q$docroot\E group-set data-people manage_data on 2>/dev/null);
qx($^X \Q$users\E --docroot \Q$docroot\E group-set data-people ui on 2>/dev/null);
qx($^X \Q$users\E --docroot \Q$docroot\E group-add writer data-people 2>/dev/null);

local $Lazysite::Auth::Session::LAZYSITE_DIR = "$docroot/lazysite";
unless ( -f "$docroot/lazysite/auth/.secret" ) {
    open my $sf, '>', "$docroot/lazysite/auth/.secret" or die $!;
    print {$sf} 'a' x 64;
    close $sf;
    chmod 0600, "$docroot/lazysite/auth/.secret";
}

# The legacy three-field payload, as t/integration/60 uses and for its reason:
# the four-field form carries a session id, and an invented one is not in the
# registry, so the caller would come back anonymous.
sub cookie_for {
    my ($user) = @_;
    require Digest::SHA;
    my $secret = Lazysite::Auth::Session::_auth_secret_read();
    return '' unless length $secret;
    my $payload = "$user:" . time . ':';
    return 'lazysite_auth='
        . $payload . ':'
        . Digest::SHA::hmac_sha256_hex( $payload, $secret );
}

sub hit {
    my (%o)  = @_;
    my $body = $o{body} // '';
    my $tmp  = "$docroot/.body";
    open my $bf, '>', $tmp or die $!;
    print {$bf} $body;
    close $bf;
    local %ENV = (
        env_passthrough(),
        DOCUMENT_ROOT  => $docroot,
        REQUEST_METHOD => ( $o{method} // 'GET' ),
        QUERY_STRING   => ( $o{qs}     // '' ),
        CONTENT_LENGTH => length($body),
    );
    $ENV{HTTP_COOKIE}       = $o{cookie} if defined $o{cookie};
    $ENV{HTTP_X_CSRF_TOKEN} = $o{csrf}   if defined $o{csrf};
    my $out    = qx($^X \Q$root/lazysite-data.pl\E < \Q$tmp\E 2>/dev/null);
    my ($st)   = $out =~ /Status:\s*(\d+)/;
    my ($json) = $out =~ /\r?\n\r?\n(.*)/s;
    return ( $st // 0, ( eval { decode_json( $json // '' ) } || {} ) );
}

my $COOKIE = cookie_for('writer');
ok( length $COOKIE, 'a session cookie can be minted' )
    or BAIL_OUT('no cookie - every assertion below would be meaningless');

my ( undef, $g ) = hit( qs => 'csrf=1', cookie => $COOKIE );
my $csrf = $g->{token} // '';
ok( length $csrf, 'a CSRF token is minted for the verified account' )
    or BAIL_OUT('no CSRF token - the write below could not be attempted');

# NO key in the body: Manager::Data picks insert over update on "is there a
# key", and an insert is what stamps created_by (update passes partial => 1).
my ( $ps, $p ) = hit(
    method => 'POST',
    qs     => 'table=notes&action=save',
    cookie => $COOKIE,
    csrf   => $csrf,
    body   => encode_json( { row => { code => 'r1', body => 'signed in' } } ),
);
is( $ps, 200, 'the signed-in write is accepted' );
ok( $p->{ok}, 'and reports ok' ) or diag( explain $p );

sub row {
    my ($code) = @_;
    my $rows = read_rows( $docroot, 'notes', as => 'operator' );
    for my $r ( @{ $rows->{rows} || [] } ) { return $r if $r->{code} eq $code }
    return undef;
}

my $r1 = row('r1');
ok( $r1, 'the row is there' );
is( $r1->{created_by}, 'writer',
    'created_by names the signed-in account that wrote it' )
    or diag( 'The endpoint verified the session and had the account in hand, '
        . 'then called the row writer without it: Manager::Data::$auth_user '
        . 'kept its empty default and _stamp wrote undef. An empty created_by '
        . 'already means "written anonymously", so this row made a false claim '
        . 'about its own provenance.' );

# An UPDATE stamps the amender, not the creator (partial => 1 skips created_*).
my ( $us, $u ) = hit(
    method => 'POST',
    qs     => 'table=notes&action=save',
    cookie => $COOKIE,
    csrf   => $csrf,
    body   => encode_json( { key => 'r1', row => { body => 'amended' } } ),
);
is( $us,                     200,      'an update is accepted' ) or diag( explain $u );
is( row('r1')->{updated_by}, 'writer', 'updated_by names the amender' );

# THE OTHER DIRECTION, which is why the fix is "pass the verified identity"
# rather than "always fill the column". An anonymous write must still record
# nobody - a public form's row has no author and must not acquire one.
my ( $as, $a ) = hit(
    method => 'POST',
    qs     => 'table=notes&action=save',
    body   => encode_json( { row => { code => 'r2', body => 'anonymous' } } ),
);
is( $as,        403,         'an anonymous write is refused outright' );
is( $a->{kind}, 'anonymous', 'and says so by kind' );
ok( !defined row('r2'), 'so no row was written for it' );

done_testing();
