#!/usr/bin/perl
# DP-3 write half: a page's JavaScript can write, and `writable=` does not
# decide who may.
#
# THE PLAN CALLED THIS "inline writable= writes", and the obvious reading - a
# page declaring a table writable makes it writable - is the one thing it must
# not do. The endpoint is reached by a URL and cannot see which page called it,
# so a marker in front matter could never gate anything: a page saying
# `writable` would be a promise the enforcement layer never hears.
#
# So the rule lives where it can be enforced - a verified session, a CSRF
# token, and manage_data - and `writable=` is a note to the page's own script
# about whether to offer editing controls.
#
# ANONYMOUS WRITES ARE WHAT FORMS ARE FOR: a solved problem here, with rate
# limits, spam controls and a handler that vets what it accepts. A data binding
# taking anonymous writes would rebuild that surface without any of it.
use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use JSON::PP;
use FindBin;
use lib "$FindBin::Bin/../lib";

BEGIN {
    eval { require DBI; require DBD::SQLite; require YAML::PP; 1 }
        or plan skip_all => 'DBI/DBD::SQLite/YAML::PP not available';
}
use TestHelper qw(repo_root env_passthrough);
use Lazysite::Data::Tables   qw(apply_schema read_rows);
use Lazysite::Auth::Session  ();

my $root    = repo_root();
my $docroot = tempdir( CLEANUP => 1 );
make_path( "$docroot/lazysite/db/tables", "$docroot/lazysite/auth" );
open my $cf, '>', "$docroot/lazysite/lazysite.conf" or die $!;
print {$cf} "site_name: T\nplugins:\n  - plugins/data.pl\n";
close $cf;
open my $df, '>', "$docroot/lazysite/db/tables/notes.yaml" or die $!;
print {$df} "public: true\nkey: code\nfields:\n  code:\n    type: text\n"
    . "    required: true\n  body:\n    type: text\n";
close $df;
apply_schema( $docroot, 'notes' );

# A SECOND TABLE THAT NARROWS. `writable_by` has been in the descriptor since
# DP-1 - validated, exported, named in the MCP tool's documentation - and
# nothing enforced it, so an operator who wrote it was given a promise no code
# kept.
open my $nf, '>', "$docroot/lazysite/db/tables/minutes.yaml" or die $!;
print {$nf} "key: code\nwritable_by:\n  - secretaries\n"
    . "fields:\n  code:\n    type: text\n    required: true\n";
close $nf;
apply_schema( $docroot, 'minutes' );

# An account with manage_data, and one without.
my $users = "$root/tools/lazysite-users.pl";
qx($^X \Q$users\E --docroot \Q$docroot\E setup-sysop --user sjm pw123456789 2>/dev/null);
qx($^X \Q$users\E --docroot \Q$docroot\E add writer pw123456789 2>/dev/null);
qx($^X \Q$users\E --docroot \Q$docroot\E group-set data-people manage_data on 2>/dev/null);
qx($^X \Q$users\E --docroot \Q$docroot\E group-add writer data-people 2>/dev/null);

# SM682: a LEARNER - the external, semi-trusted user this capability exists for.
# It holds write_data and NOT manage_data, and it is in `secretaries`, which is
# the group `minutes` names in its writable_by. So it may write that table and
# no other.
qx($^X \Q$users\E --docroot \Q$docroot\E add learner pw123456789 2>/dev/null);
qx($^X \Q$users\E --docroot \Q$docroot\E group-set secretaries write_data on 2>/dev/null);
qx($^X \Q$users\E --docroot \Q$docroot\E group-set secretaries ui on 2>/dev/null);
qx($^X \Q$users\E --docroot \Q$docroot\E group-add learner secretaries 2>/dev/null);
qx($^X \Q$users\E --docroot \Q$docroot\E add reader pw123456789 2>/dev/null);

# A session cookie the endpoint will verify, minted the way lazysite-auth does.
#
# THE SECRET IS CREATED HERE IF IT IS ABSENT. The first version of this file
# returned empty when it was, which turned into skip_all - and a skipped
# subtest reports as a pass, so the whole write half would have been "green"
# while testing nothing. That is the failure mode this suite keeps catching in
# other people's code.
local $Lazysite::Auth::Session::LAZYSITE_DIR = "$docroot/lazysite";
unless ( -f "$docroot/lazysite/auth/.secret" ) {
    open my $sf, '>', "$docroot/lazysite/auth/.secret" or die $!;
    print {$sf} 'a' x 64;
    close $sf;
    chmod 0600, "$docroot/lazysite/auth/.secret";
}
sub cookie_for {
    my ($user) = @_;
    require Digest::SHA;

    # THE MODULE'S OWN READER, not a hand-rolled one. Reading the file here
    # meant reproducing exactly how it is chomped and trimmed, and getting that
    # subtly wrong produced a signature mismatch that looked like a broken
    # endpoint. A fixture that re-implements the thing it is testing against
    # will differ from it eventually.
    my $secret = Lazysite::Auth::Session::_auth_secret_read();
    return '' unless length $secret;
    # THE LEGACY THREE-FIELD PAYLOAD (user:ts:groups), on purpose. The current
    # four-field form carries a session id, and a made-up one is not in the
    # session registry - so verify_session_cookie treats it as REVOKED and the
    # caller comes back anonymous. Minting a registry entry as well would be
    # testing the login flow rather than this endpoint.
    my $payload = "$user:" . time . ':';
    my $sig = Digest::SHA::hmac_sha256_hex( $payload, $secret );
    return 'lazysite_auth=' . $payload . ':' . $sig;
}

sub hit {
    my (%o) = @_;
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
    my $out = qx($^X \Q$root/lazysite-data.pl\E < \Q$tmp\E 2>/dev/null);
    my ($st)   = $out =~ /Status:\s*(\d+)/;
    my ($json) = $out =~ /\r?\n\r?\n(.*)/s;
    return ( $st // 0, ( eval { decode_json( $json // '' ) } || {} ) );
}

my $WRITER = cookie_for('writer');
# NOT skip_all. A test that quietly stops testing is worse than no test, and
# this file's whole subject is what the endpoint refuses.
ok( length $WRITER, 'a session cookie can be minted for the test' )
    or BAIL_OUT('no cookie - every assertion below would be meaningless');

subtest 'an ANONYMOUS write is refused' => sub {
    my ( $st, $d ) = hit(
        method => 'POST',
        qs     => 'table=notes',
        body   => encode_json( { row => { code => 'A1' } } ),
    );
    is( $st, 403, 'refused' );
    is( $d->{kind}, 'anonymous', 'because nobody is signed in' );
    like( $d->{error}, qr/public form/, 'and it says what IS for that' )
        or diag( 'Anonymous data collection is a solved problem here; a '
            . 'binding that took it would rebuild forms without the rate '
            . 'limits or the spam controls.' );
};

subtest 'a signed-in write with NO CSRF token is refused' => sub {
    my ( $st, $d ) = hit(
        method => 'POST',
        qs     => 'table=notes',
        cookie => $WRITER,
        body   => encode_json( { row => { code => 'A1' } } ),
    );
    is( $st, 403, 'refused' );
    is( $d->{kind}, 'csrf', 'on CSRF grounds' )
        or diag( 'The cookie travels automatically, so without this any page '
            . 'anywhere could make a signed-in reader write to this site.' );
};

subtest 'with a token, the write goes through' => sub {
    my ( $ct, $cd ) = hit( qs => 'csrf=1', cookie => $WRITER );
    is( $ct, 200, 'a token is minted for a verified session' );
    ok( $cd->{token}, 'and returned' ) or return;

    my ( $st, $d ) = hit(
        method => 'POST',
        qs     => 'table=notes',
        cookie => $WRITER,
        csrf   => $cd->{token},
        body   => encode_json( { row => { code => 'A1', body => 'first' } } ),
    );
    ok( $d->{ok}, 'the row saves' ) or diag( $d->{error} // '' );
    is( scalar @{ read_rows( $docroot, 'notes', as => 'operator' )->{rows} }, 1, 'and is stored' );

    # The value layer still applies - the endpoint is a door, not a bypass.
    my ( $bs, $bd ) = hit(
        method => 'POST',
        qs     => 'table=notes',
        cookie => $WRITER,
        csrf   => $cd->{token},
        body   => encode_json( { row => { body => 'no key' } } ),
    );
    ok( !$bd->{ok}, 'a row missing its required field is still refused' );
};

subtest 'SM682: write_data writes a NAMED table, and reaches nothing else' => sub {
    # The capability exists because manage_data is all-or-nothing: it carries
    # table create, alter and drop AND read/write across every table on the
    # instance. Handing that to a group of external learners so they can submit
    # their own work is the thing this avoids.
    #
    # THE CREDENTIAL IS THE POINT: write_data and NOT manage_data. A grant
    # holding both would prove nothing about which one opened the door.
    my $c = cookie_for('learner');
    my ( undef, $cd ) = hit( qs => 'csrf=1', cookie => $c );

    # `minutes` names `secretaries` in writable_by, and the learner is in it.
    my ( $st, $d ) = hit(
        method => 'POST',
        qs     => 'table=minutes',
        cookie => $c,
        csrf   => $cd->{token},
        body   => encode_json( { row => { code => 'L1' } } ),
    );
    is( $st, 200, 'a named table accepts the write' )
        or diag( 'got: ' . ( $d->{error} // '(no error)' ) );
    ok( ( grep { $_->{code} eq 'L1' } @{ read_rows( $docroot, 'minutes', as => 'operator' )->{rows} } ),
        'and the row is stored' );

    # `notes` names NOBODY. For manage_data an empty list means "no extra
    # narrowing"; for write_data it is an ALLOW-LIST and an unnamed table is
    # closed. Without this inversion write_data would be instance-wide write
    # under a new name, which is the grant it exists to avoid.
    my ( $st2, $d2 ) = hit(
        method => 'POST',
        qs     => 'table=notes',
        cookie => $c,
        csrf   => $cd->{token},
        body   => encode_json( { row => { code => 'L2', body => 'x' } } ),
    );
    is( $st2, 403, 'a table naming nobody is CLOSED to write_data' )
        or diag( 'An empty writable_by must not read as "anyone with '
            . 'write_data" - that is instance-wide write with a new name.' );
    like( $d2->{error}, qr/names no writable_by groups/,
        'and the refusal says why, and what a sysop would change' );
    ok( !( grep { $_->{code} eq 'L2' } @{ read_rows( $docroot, 'notes', as => 'operator' )->{rows} } ),
        'nothing is stored' );
};

subtest 'SM682: write_data does not reach the schema verbs' => sub {
    # The whole point is that this grant is NOT data administration. If it
    # reached data-table-save it would be manage_data with extra steps.
    my $caps = qx($^X \Q$users\E --docroot \Q$docroot\E permissions learner 2>&1);
    like( $caps, qr/write_data\s+Y/, 'the learner holds write_data' );
    unlike( $caps, qr/manage_data\s+Y/, 'and does NOT hold manage_data' )
        or diag( 'If it did, every assertion above proves nothing about which '
            . 'capability opened the door.' );
};

subtest 'writable_by narrows, and manage_data alone is not enough' => sub {
    # The writer holds manage_data and may write `notes`. `minutes` names a
    # group the writer is not in, so the SAME account with the SAME capability
    # and a valid token must be refused there.
    my $c = cookie_for('writer');
    my ( undef, $cd ) = hit( qs => 'csrf=1', cookie => $c );

    my ( $st, $d ) = hit(
        method => 'POST',
        qs     => 'table=minutes',
        cookie => $c,
        csrf   => $cd->{token},
        body   => encode_json( { row => { code => 'M1' } } ),
    );
    is( $st, 403, 'the narrowed table refuses' );
    like( $d->{error}, qr/secretaries/, 'naming the group that may write' )
        or diag( 'A refusal that does not say which group leaves the operator '
            . 'guessing at a list they cannot see from here.' );
    ok( !( grep { $_->{code} eq 'M1' } @{ read_rows( $docroot, 'minutes', as => 'operator' )->{rows} } ),
        'and nothing is stored' );

    # The same account, the same token, the table that does NOT narrow.
    my ( $st2 ) = hit(
        method => 'POST',
        qs     => 'table=notes',
        cookie => $c,
        csrf   => $cd->{token},
        body   => encode_json( { row => { code => 'N9' } } ),
    );
    is( $st2, 200, 'an un-narrowed table still accepts the same account' )
        or diag( 'If this fails the narrowing is not narrowing, it is a '
            . 'blanket refusal.' );
};

subtest 'a group listed in writable_by may write it' => sub {
    qx($^X \Q$users\E --docroot \Q$docroot\E group-set secretaries manage_data on 2>/dev/null);
    qx($^X \Q$users\E --docroot \Q$docroot\E add clerk pw123456789 2>/dev/null);
    qx($^X \Q$users\E --docroot \Q$docroot\E group-add clerk secretaries 2>/dev/null);

    my $c = cookie_for('clerk');
    my ( undef, $cd ) = hit( qs => 'csrf=1', cookie => $c );
    my ( $st, $d ) = hit(
        method => 'POST',
        qs     => 'table=minutes',
        cookie => $c,
        csrf   => $cd->{token},
        body   => encode_json( { row => { code => 'M2' } } ),
    );
    is( $st, 200, 'the listed group writes' ) or diag( explain $d );
    ok( ( grep { $_->{code} eq 'M2' } @{ read_rows( $docroot, 'minutes', as => 'operator' )->{rows} } ),
        'and the row is there' );
};

subtest 'a signed-in account WITHOUT manage_data is refused' => sub {
    # The capability is the only real gate - `writable=` on a page cannot reach
    # here - so an account that has a valid session and a valid token must
    # still be refused. Without this case, removing the capability check
    # entirely passes every other assertion in this file.
    my $reader = cookie_for('reader');
    my ( $ct, $cd ) = hit( qs => 'csrf=1', cookie => $reader );
    is( $ct, 200, 'the account is signed in' );
    ok( $cd->{token}, 'and can get a token' )
        or diag( 'A token is not a permission - it proves the request came '
            . 'from this session, not that the session may write.' );

    my ( $st, $d ) = hit(
        method => 'POST',
        qs     => 'table=notes',
        cookie => $reader,
        csrf   => $cd->{token},
        body   => encode_json( { row => { code => 'R1' } } ),
    );
    is( $st, 403, 'the write is refused' );
    is( $d->{kind}, 'forbidden', 'on capability grounds' );
    like( $d->{error}, qr/manage_data/, 'naming what is missing' );

    ok( !( grep { $_->{code} eq 'R1' } @{ read_rows( $docroot, 'notes', as => 'operator' )->{rows} } ),
        'and nothing is stored' );
};

subtest 'an anonymous CSRF request gets nothing to replay' => sub {
    my ( $st, $d ) = hit( qs => 'csrf=1' );
    is( $st, 403, 'refused' );
    ok( !$d->{token}, 'and no token is issued' )
        or diag( 'A token handed to an anonymous caller is a token anybody '
            . 'can fetch, which is not a token.' );
};

subtest 'adding a write path did not close the read one' => sub {
    # `notes` is declared `public: true`, so this is the published case and it
    # must keep working: the point of the endpoint is a page's own script
    # reading rows without a login.
    my ( $st, $d ) = hit( qs => 'table=notes' );
    is( $st, 200, 'an anonymous read of a PUBLISHED table still answers' )
        or diag( 'Adding a write path must not close the read one.' );
    ok( $d->{ok}, 'with rows' );
};

subtest 'an UNPUBLISHED table is invisible, and says nothing about itself'
    => sub {
    # SM476. `minutes` carries no `public:`, so it defaults closed.
    my ( $st, $d ) = hit( qs => 'table=minutes' );
    is( $st, 404, 'an anonymous read is refused' )
        or diag( 'A table is a store, not a published artefact. Until an '
            . 'operator publishes it, an anonymous visitor sees nothing.' );

    # THE SAME ANSWER AS A TABLE THAT DOES NOT EXIST, word for word. Anything
    # that distinguishes them tells an anonymous caller which tables this site
    # has, which is most of what is worth having from a store you cannot read.
    my ( $st2, $d2 ) = hit( qs => 'table=nosuchtableatall' );
    is( $st2, $st, 'the same status as a table that does not exist' );
    is( $d2->{error}, $d->{error}, 'and the same wording, exactly' )
        or diag( 'Different wording is a directory listing for anyone who '
            . 'bothers to diff two responses.' );

    # A signed-in account with no ACL narrowing it DOES see it: `public` is
    # about anonymous visitors, not about locking the table away entirely.
    my ( $st3, $d3 ) = hit( qs => 'table=minutes', cookie => cookie_for('writer') );
    is( $st3, 200, 'but a signed-in account reads it' )
        or diag( 'public: false means "not for anonymous visitors". Who among '
            . 'the signed-in may read is the acls.json read list.' );
    };

done_testing();
