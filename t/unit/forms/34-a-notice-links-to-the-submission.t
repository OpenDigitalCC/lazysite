#!/usr/bin/perl
# SM938 D5 / R18: A SUBMISSION NOTICE LINKS TO THE SUBMISSION.
#
# The operator's words: the bell "should show link to the thing that happened".
# A submission notice linked to /manager/handlers - a SECTION - and no manager
# page addressed a single submission. SM928 defect 4 recorded why it stopped
# there: a deep link needs the store PATH, which only the handler that stored the
# row knows.
#
# WHAT THIS PINS, end to end through the real form handler:
#   - the file handler reports the row it wrote (store + id), and the notice's
#     url carries exactly that;
#   - the link resolves: form-submission returns that row, as typed;
#   - the id is the SAME id the submissions table gives the row - one
#     definition, so the link and the table cannot disagree;
#   - a row that has gone is not-found in words that say so, a malformed id is
#     refused, and the read is confined to the submission stores like the table;
#   - a form with no stored row still links somewhere real (the Handlers page);
#   - the page shows submitted values as text, never as markup.
use strict;
use warnings;
use Test::More;
use JSON::PP    qw(decode_json);
use Digest::SHA qw(hmac_sha256_hex);
use File::Path  qw(make_path);
use FindBin;
use lib "$FindBin::Bin/../../lib", "$FindBin::Bin/../../../lib";
use TestHelper qw(repo_root site_tempdir);
use Lazysite::Manager::Plugins ();
use Lazysite::Handlers         ();

my $PLUGIN = repo_root() . '/plugins/form-handler.pl';
plan skip_all => "no $PLUGIN" unless -f $PLUGIN;

my $d = site_tempdir();
make_path( "$d/lazysite/forms", "$d/lazysite/logs" );
my $SECRET = 'test-secret-1234567890';
my $STORE  = 'lazysite/forms/submissions/contact.jsonl';

sub spit  { my ( $p, $t ) = @_; open my $fh, '>', $p or die "$p: $!"; print {$fh} $t; close $fh; return }
sub slurp { my ($p) = @_; open my $fh, '<', $p or return ''; local $/; my $t = <$fh>; close $fh; return $t }

spit( "$d/lazysite/lazysite.conf",         "site_name: T\nsite_url: https://example.com\n" );
spit( "$d/lazysite/forms/.secret",         "$SECRET\n" );
spit( "$d/lazysite/forms/handlers.conf",   "handlers:\n  - id: jsonl\n    type: file\n" );
spit( "$d/lazysite/forms/contact.conf",    "targets:\n  - handler: jsonl\n" );
$Lazysite::Manager::Plugins::DOCROOT = $d;
$Lazysite::Handlers::DOCROOT         = $d;

my $BOUNDARY = 'Sbnd938';
sub submit {
    my (%fields) = @_;
    my $ts   = time() - 10;
    my $body = '';
    for my $pair ( [ '_form', 'contact' ], [ '_ts', $ts ],
        [ '_tk', hmac_sha256_hex( $ts, $SECRET ) ], [ '_hp', '' ],
        map { [ $_, $fields{$_} ] } sort keys %fields )
    {
        $body .= "--$BOUNDARY\r\nContent-Disposition: form-data; name=\"$pair->[0]\"\r\n\r\n$pair->[1]\r\n";
    }
    $body .= "--$BOUNDARY--\r\n";
    spit( "$d/post.bin", $body );
    local $ENV{REQUEST_METHOD} = 'POST';
    local $ENV{CONTENT_TYPE}   = "multipart/form-data; boundary=$BOUNDARY";
    local $ENV{CONTENT_LENGTH} = length $body;
    local $ENV{DOCUMENT_ROOT}  = $d;
    local $ENV{REMOTE_ADDR}    = '203.0.113.7';
    local $ENV{HTTP_HOST}      = 'example.com';
    qx($^X \Q$PLUGIN\E < \Q$d/post.bin\E 2>/dev/null);
    return;
}
sub last_notice {
    my @l = grep {/\S/} split /\n/, slurp("$d/lazysite/logs/notices.jsonl");
    return @l ? decode_json( $l[-1] ) : {};
}

# Two submissions, and the notice for the SECOND: a read that returned the first
# row of the store would otherwise pass. UTF-8 bytes on the wire, as a browser
# sends them.
submit( name => 'Bob', message => 'first' );
submit( name => 'Ann', message => "caf\xc3\xa9 \xe2\x98\xba" );
my $n = last_notice();
my ($id) = ( $n->{url} // '' ) =~ m{\A/manager/submission\?file=\Q$STORE\E&id=([0-9a-f]{16})\z};

subtest 'the notice links to the row that was stored' => sub {
    ok( $id, 'the url names the store and a row id' )
        or diag( 'got url: ' . ( $n->{url} // '(none)' ) );
};

subtest 'the link resolves to that submission, as typed' => sub {
    plan skip_all => 'no id' unless $id;
    my $r = Lazysite::Manager::Plugins::action_form_submission( $STORE, $id );
    ok( $r->{ok}, 'read' ) or return diag explain $r;
    is( $r->{record}{name}, 'Ann', 'the row the visitor sent' );
    is( $r->{record}{message}, "caf\x{e9} \x{263a}", 'its text as typed, non-ASCII included' );
    is_deeply( $r->{fields}, [qw(message name)], 'fields are what the visitor sent' );
    ok( ( grep { $_ eq '_submitted' } @{ $r->{meta} } ), 'and the site\'s own keys are kept apart' );
};

subtest 'the link\'s id is the id the table gives the row' => sub {
    plan skip_all => 'no id' unless $id;
    my $t = Lazysite::Manager::Plugins::action_form_submissions($STORE);
    my ($ann) = grep { $_->{name} eq 'Ann' } @{ $t->{rows} };
    is( scalar @{ $t->{rows} }, 2, 'two rows in the table' );
    is( $ann && $ann->{_id}, $id, 'and the linked row carries the same id there' )
        or diag( 'Two definitions of a row id would make the link and the table '
            . 'name the same submission differently.' );
};

subtest 'a gone row, a malformed id, a store outside the stores' => sub {
    plan skip_all => 'no id' unless $id;
    Lazysite::Manager::Plugins::action_form_submission_delete( $STORE, $id );
    my $r = Lazysite::Manager::Plugins::action_form_submission( $STORE, $id );
    is( $r->{kind}, 'not-found', 'a deleted row is not-found' );
    like( $r->{error}, qr/deleted since the notice was sent/, 'in words that say what probably happened' );
    like( $r->{error}, qr/\Q$id\E on the form 'contact'/, 'naming the id and the form' );
    unlike( $r->{error}, qr{/|\.jsonl}, 'and no path to the store (SM953)' )
        or diag('The owner: a message should not expose file paths.');
    my $gone = Lazysite::Manager::Plugins::action_form_submission(
        'lazysite/forms/submissions/nosuch.jsonl', $id );
    is( $gone->{kind}, 'not-found', 'a store that does not exist is not-found' );
    unlike( $gone->{error} // '', qr{/|\.jsonl}, 'and says so without a path' ) or diag( $gone->{error} );
    is( Lazysite::Manager::Plugins::action_form_submission( $STORE, 'nothex' )->{field}, 'id',
        'a malformed id is refused, naming the field' );
    # A real file outside the stores, holding a row with a known id - so the
    # refusal has to be the confinement, not the file being absent.
    make_path("$d/lazysite/auth");
    my $line = '{"sid":"x"}';
    spit( "$d/lazysite/auth/sessions.jsonl", "$line\n" );
    my $out = Lazysite::Manager::Plugins::action_form_submission( 'lazysite/auth/sessions.jsonl',
        Lazysite::Handlers::submission_row_id($line) );
    ok( !$out->{ok}, 'a file outside the submission stores is refused' );
    like( $out->{error} // '', qr/Invalid submissions file/, 'by the same confinement the table uses' );
};

subtest 'without a stored row the notice still links somewhere real' => sub {
    my $src = slurp($PLUGIN);
    my ($sub) = $src =~ /(sub _submission_url \{.*?\n\})/s;
    ok( $sub, 'found the url builder' ) or return;
    my $f = eval "package T; $sub; \\&_submission_url" or die $@;
    is( $f->(undef), '/manager/handlers', 'no stored row: the Handlers page' );
    is( $f->( { file => $STORE, id => 'zz' } ), '/manager/handlers', 'a malformed id is not linked' );
    is( $f->( { file => 'my store/c.jsonl', id => 'a' x 16 } ),
        '/manager/submission?file=my%20store/c.jsonl&id=' . ( 'a' x 16 ), 'a store path is escaped' );
};

subtest 'the page shows submitted values as text' => sub {
    my $page = slurp( repo_root() . '/starter/manager/submission.md' );
    like( $page, qr/action=form-submission&/, 'it reads through form-submission' );
    unlike( $page, qr/innerHTML/, 'and never writes markup - a submitted value is untrusted' );
};

done_testing();
