#!/usr/bin/perl
# SM858: an operator approves an account from a button on the Submissions view,
# and the system does the typing.
#
# Driven end to end: submissions are POSTED THROUGH THE REAL FORM HANDLER, so the
# field the form's conf names (`account_email:`) is held to the key the handler
# actually stored - the conf is read by Lazysite::Handlers::form_account_email
# and the row is written by plugins/form-handler.pl, and this is where the two
# meet. The approval is then made over the manager API as a signed-in person
# (ManagerSession), and every assertion reads the account store afterwards
# rather than trusting the answer.
use strict;
use warnings;
use Test::More;
use JSON::PP    qw(decode_json);
use Digest::SHA qw(hmac_sha256_hex);
use File::Path  qw(make_path);
use FindBin;
use lib "$FindBin::Bin/../../lib";
use lib "$FindBin::Bin/../../../lib";
use TestHelper     qw(repo_root);
use ManagerSession qw(new_site);
use Lazysite::ControlApi::Actions;

my $PLUGIN = repo_root() . '/plugins/form-handler.pl';
plan skip_all => "no $PLUGIN" unless -f $PLUGIN;

my $s = new_site( root => repo_root() );
my $d = $s->docroot;
make_path("$d/lazysite/forms");
my $SECRET = 'test-secret-approve-200';
sub spit { my ( $p, $t ) = @_; open my $fh, '>', $p or die "$p: $!"; print {$fh} $t; close $fh; return }
spit( "$d/lazysite/forms/.secret", "$SECRET\n" );
spit( "$d/lazysite/forms/handlers.conf",
    "handlers:\n  - id: jsonl\n    type: file\n    name: Local\n    path: lazysite/forms/submissions\n"
        . "  - id: other\n    type: file\n    name: Other\n    path: lazysite/forms/other\n" );
spit( "$d/lazysite/forms/register.conf", "targets:\n  - handler: jsonl\naccount_email: email\n" );
spit( "$d/lazysite/forms/plain.conf",    "targets:\n  - handler: jsonl\n" );
my $STORE = 'lazysite/forms/submissions/register.jsonl';

my $ip = 0;
sub post {
    my ( $form, %f ) = @_;
    $ip++;
    my $ts   = time() - 10;
    my $body = join '&', map { "$_->[0]=$_->[1]" } (
        [ _form => $form ], [ _ts => $ts ], [ _tk => hmac_sha256_hex( $ts, $SECRET ) ],
        [ _hp => '' ], map { [ $_ => $f{$_} ] } sort keys %f );
    spit( "$d/post.txt", $body );
    local $ENV{REQUEST_METHOD} = 'POST';
    local $ENV{CONTENT_TYPE}   = 'application/x-www-form-urlencoded';
    local $ENV{CONTENT_LENGTH} = length $body;
    local $ENV{DOCUMENT_ROOT}  = $d;
    local $ENV{REMOTE_ADDR}    = "10.9.$ip.1";
    local $ENV{HTTP_ACCEPT}    = 'application/json';
    qx($^X \Q$PLUGIN\E < \Q$d/post.txt\E 2>/dev/null);
    return;
}

# The stored rows, as the store holds them.
sub rows {
    my ($form) = @_;
    open my $fh, '<:utf8', "$d/lazysite/forms/submissions/$form.jsonl" or return ();
    my @r = map { decode_json( do { ( my $l = $_ ) =~ s/\s+\z//; utf8::encode($l); $l } ) } grep { /\S/ } <$fh>;
    close $fh;
    return @r;
}

# The rows with their ids, as the viewer gets them.
sub listed {
    my ($form) = @_;
    my $r = $s->call( 'boss', 'form-submissions',
        query => "action=form-submissions&file=lazysite/forms/submissions/$form.jsonl" );
    return $r;
}
sub row_for {
    my ( $form, $field, $value ) = @_;
    my ($row) = grep { ( $_->{$field} // '' ) eq $value } @{ listed($form)->{rows} || [] };
    return $row;
}
sub accounts {
    open my $fh, '<', "$d/lazysite/auth/users" or return ();
    my @u = map { ( split /:/ )[0] } grep { /\S/ } <$fh>;
    close $fh;
    return sort @u;
}
sub settings {
    open my $fh, '<:raw', "$d/lazysite/auth/user-settings.json" or return {};
    local $/;
    my $j = eval { decode_json(<$fh>) } || {};
    close $fh;
    return $j;
}
sub approve {
    my ( $who, $form, $id, %extra ) = @_;
    return $s->call( $who, 'form-submission-approve',
        body => { file => "lazysite/forms/submissions/$form.jsonl", id => $id, %extra } );
}

# --- the people -------------------------------------------------------------
my @ALL = qw(ui manage_users read_submissions create_sub_users manage_forms);
$s->add_user('boss');
$s->grant( 'boss', 'ops', [qw(ui manage_users read_submissions)], \@ALL );
$s->add_user('clerk');
$s->users( 'add', 'Bob', 'pw123456789' );    # a name that differs only in case
$s->users( 'add', 'zed', 'pw123456789' );
$s->users( 'set', 'zed', 'email', 'dave@example.org' );

post( 'register', name => 'Ada', email => 'Ada.Lovelace@example.org' );
post( 'register', name => 'Jo',  email => 'jo%2Bhn@example.org' );
post( 'register', name => 'Bob', email => 'bob@example.org' );
post( 'register', name => 'Dave', email => 'dave@example.org' );
post( 'register', name => 'Eve', email => 'eve@example.org',
    message => 'see+https://one.example.com/a+and+https://two.example.org/b' );
post( 'register', name => 'NoMail', email => '' );
post( 'plain', name => 'Carol', email => 'carol@example.org' );
post( 'register', name => 'Zed', email => 'zzz@example.org' );

is( scalar( () = rows('register') ), 7, 'the canary: the real handler stored seven registrations' )
    or BAIL_OUT('the form handler did not store the fixture');

# --- the gate ----------------------------------------------------------------

subtest 'a manager who may not create accounts cannot create one here' => sub {
    my $ada = row_for( 'register', email => 'Ada.Lovelace@example.org' ) or return fail('no row');
    my @before = accounts();
    for my $grant ( [qw(ui read_submissions)], [qw(ui read_submissions create_sub_users)] ) {
        $s->grant( 'clerk', 'desk', $grant, \@ALL );
        my $r = approve( 'clerk', 'register', $ada->{_id} );
        ok( ManagerSession->refused_for_capability($r), "refused holding @$grant" )
            or diag( 'got: ' . ( $r->{error} // $r->{_raw} // '' ) );
        like( $r->{error} // '', qr/manage_users/, 'naming the capability it lacks' );
        is_deeply( [ accounts() ], \@before, 'and no account was created' );
    }
    ok( !exists Lazysite::ControlApi::Actions::need_caps()->{'form-submission-approve'},
        'no token can reach it: the action has no token gate (cookie-only)' );
};

# --- the approval ------------------------------------------------------------

my $ada = row_for( 'register', email => 'Ada.Lovelace@example.org' );
subtest 'approval creates the account from the address on the row' => sub {
    is( listed('register')->{account_email}, 'email', 'the store reports the field its form names' );
    my $r = approve( 'boss', 'register', $ada->{_id}, email => 'mallory@example.net' );
    ok( $r->{ok}, 'approved' ) or diag( explain $r );
    is( $r->{user}, 'ada.lovelace', 'the username is the local part, lowercased' );
    ok( ( grep { $_ eq 'ada.lovelace' } accounts() ), 'the account exists in the store' );
    is( settings()->{'ada.lovelace'}{email}, 'Ada.Lovelace@example.org',
        'the address recorded is the SUBMISSION\'s, not one the caller sent' );
    ok( length( $r->{claim} // '' ), 'and a claim link was minted' );
    my ($row) = grep { ( $_->{email} // '' ) eq 'Ada.Lovelace@example.org' } rows('register');
    is( $row->{_approved_account}, 'ada.lovelace', 'the row records the account it became' );
    is( $row->{_approved_by},      'boss',         'and who approved it' );

    open my $fh, '<', "$d/lazysite/logs/audit.log" or return fail('no audit log');
    my @l = grep { /form-submission-approve/ && /\| ok \|/ } <$fh>;
    close $fh;
    like( $l[-1] // '', qr/\| boss \| form-submission-approve \| \Q$STORE\E \|.*\| ok \|.*id=$ada->{_id} account=ada\.lovelace/,
        'the trail says who approved which submission into which account' );
};

subtest 'approving twice does not make a second account' => sub {
    my @before = accounts();
    my $again  = row_for( 'register', email => 'Ada.Lovelace@example.org' );
    my $r      = approve( 'boss', 'register', $again->{_id} );
    ok( !$r->{ok}, 'the same row is refused' );
    like( $r->{error} // '', qr/already approved as the account 'ada\.lovelace'/,
        'because it was already approved, said so' );
    is_deeply( [ accounts() ], \@before, 'and no account was created' );

    # A second submission from the same person arrives at the same name.
    post( 'register', name => 'Ada again', email => 'ada.lovelace@example.org' );
    my ($second) = grep { ( $_->{name} // '' ) eq 'Ada again' } @{ listed('register')->{rows} };
    $r = approve( 'boss', 'register', $second->{_id} );
    ok( !$r->{ok}, 'a second row from the same address is refused' );
    like( $r->{error} // '', qr/an account named 'ada\.lovelace' already exists/, 'by the name it makes' );
    is_deeply( [ accounts() ], \@before, 'still one account' );
};

subtest 'every refusal names why, and creates nothing' => sub {
    my @before = accounts();
    my @cases  = (
        [ 'jo+hn@example.org', qr/local part 'jo\+hn' cannot be a username: '\+' is not allowed/,
            'a character a username may not hold is refused, not stripped' ],
        [ 'bob@example.org', qr/an account named 'Bob' already exists/,
            'a name taken in another case is refused, not suffixed or overwritten' ],
        [ 'dave@example.org', qr/already recorded on the account 'zed'/,
            'an address another account records is refused' ],
        [ 'eve@example.org', qr/quarantined/, 'a quarantined row is refused' ],
    );
    for my $c (@cases) {
        my ( $addr, $re, $label ) = @$c;
        my $row = row_for( 'register', email => $addr ) or do { fail("no row for $addr"); next };
        my $r   = approve( 'boss', 'register', $row->{_id} );
        ok( !$r->{ok}, "$addr: refused" );
        like( $r->{error} // '', $re, $label ) or diag( $r->{error} // explain $r );
    }
    my $none = row_for( 'register', name => 'NoMail' );
    my $r    = approve( 'boss', 'register', $none->{_id} );
    like( $r->{error} // '', qr/no 'email' value/, 'a row with no address is refused' );
    is_deeply( [ accounts() ], \@before, 'and none of them created an account' );
    ok( !( grep { lc $_ eq 'bob' && $_ ne 'Bob' } accounts() ), 'Bob was not shadowed by a bob' );
    is( settings()->{zed}{email}, 'dave@example.org', 'and zed is untouched' );
};

subtest 'a form without account_email offers no approval' => sub {
    my $l = listed('plain');
    ok( $l->{ok} && @{ $l->{rows} || [] }, 'the canary: the plain form has its row' );
    ok( !exists $l->{account_email}, 'the store reports no address field' );
    my $r = approve( 'boss', 'plain', $l->{rows}[0]{_id} );
    ok( !$r->{ok}, 'and approval is refused' );
    like( $r->{error} // '', qr/does not declare account_email/, 'saying why' );
    ok( !( grep { $_ eq 'carol' } accounts() ), 'no account was created' );
};

subtest 'a store named for the form but not the form\'s own is not its submissions' => sub {
    # A configured store directory the form does not write to, holding a file
    # named for it: the name is a claim about the file, not a fact.
    make_path("$d/lazysite/forms/other");
    open my $in, '<', "$d/lazysite/forms/submissions/register.jsonl" or return fail('no store');
    my ($line) = grep { /zzz\@example\.org/ } <$in>;
    close $in;
    ok( defined $line, 'the canary: a registration to copy' ) or return;
    spit( "$d/lazysite/forms/other/register.jsonl", $line );
    my $l = $s->call( 'boss', 'form-submissions',
        query => 'action=form-submissions&file=lazysite/forms/other/register.jsonl' );
    ok( $l->{ok} && @{ $l->{rows} || [] }, 'the copy is readable as a store' );
    ok( !exists $l->{account_email}, 'and reports no address field' );
    my $r = $s->call( 'boss', 'form-submission-approve',
        body => { file => 'lazysite/forms/other/register.jsonl', id => $l->{rows}[0]{_id} } );
    like( $r->{error} // '', qr/not where the form 'register' writes/, 'approval is refused, saying why' );
    ok( !( grep { $_ eq 'zzz' } accounts() ), 'and no account was created' );
};

subtest 'the one reader: what it accepts' => sub {
    require Lazysite::Handlers;
    is( Lazysite::Handlers::form_account_email("account_email: email\n"), 'email', 'a field name' );
    is( Lazysite::Handlers::form_account_email("targets:\n"), '', 'absent' );
    is( Lazysite::Handlers::form_account_email("account_email: _form\n"), '',
        'the handler\'s own bookkeeping is never the address' );
    is( Lazysite::Handlers::form_account_email("account_email: e mail\n"), '', 'not a field name' );
};

done_testing();
