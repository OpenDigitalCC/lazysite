#!/usr/bin/perl
# SM913 S4: the manager says whether a form's quarantine is on - and says what
# the form handler will actually do.
#
# The handler (plugins/form-handler.pl) is a CGI the manager cannot load, so the
# manager reads the form's config through Lazysite::Handlers::form_quarantine_state,
# a second reader of the same keys. Two readers of one setting is the defect this
# project keeps closing, so this file holds them together by BEHAVIOUR: for every
# spelling, a two-link message is posted through the real handler, and whether it
# was held must equal what the manager reports.
use strict;
use warnings;
use Test::More;
use JSON::PP    qw(decode_json);
use Digest::SHA qw(hmac_sha256_hex);
use File::Path  qw(make_path);
use FindBin;
use lib "$FindBin::Bin/../../lib";
use TestHelper qw(repo_root site_tempdir);
use Lazysite::Handlers;
use PageScript qw(extract_function page_source);

my $PLUGIN = repo_root() . '/plugins/form-handler.pl';
plan skip_all => "no $PLUGIN" unless -f $PLUGIN;

my $d = site_tempdir();
make_path("$d/lazysite/forms");
my $SECRET = 'test-secret-quarantine-35';
sub spit { my ( $p, $t ) = @_; open my $fh, '>', $p or die "$p: $!"; print {$fh} $t; close $fh; return }
spit( "$d/lazysite/forms/.secret", "$SECRET\n" );
spit( "$d/lazysite/lazysite.conf", "site_name: T\n" );
spit( "$d/lazysite/forms/handlers.conf",
    "handlers:\n  - id: jsonl\n    type: file\n    name: Local\n    path: $d/subs\n" );

my $ip = 0;
sub held_by_handler {
    my ($conf) = @_;
    spit( "$d/lazysite/forms/contact.conf", "targets:\n  - handler: jsonl\n$conf" );
    unlink "$d/subs/contact.jsonl";
    $ip++;
    my $ts   = time() - 10;
    my $body = join '&', map { "$_->[0]=$_->[1]" } (
        [ _form => 'contact' ], [ _ts => $ts ], [ _tk => hmac_sha256_hex( $ts, $SECRET ) ],
        [ _hp => '' ], [ name => 'Ada' ],
        [ message => 'see+https://one.example.com/a+and+https://two.example.org/b' ] );
    spit( "$d/post.txt", $body );
    local $ENV{REQUEST_METHOD} = 'POST';
    local $ENV{CONTENT_TYPE}   = 'application/x-www-form-urlencoded';
    local $ENV{CONTENT_LENGTH} = length $body;
    local $ENV{DOCUMENT_ROOT}  = $d;
    local $ENV{REMOTE_ADDR}    = "10.0.$ip.1";
    local $ENV{HTTP_ACCEPT}    = 'application/json';
    qx($^X \Q$PLUGIN\E < \Q$d/post.txt\E 2>/dev/null);
    open my $fh, '<', "$d/subs/contact.jsonl" or return undef;
    my @l = <$fh>;
    close $fh;
    return @l ? ( decode_json( $l[-1] )->{_quarantined} ? 1 : 0 ) : undef;
}

for my $case (
    [ 'absent (the default)', '' ],
    map( { [ "quarantine: $_", "quarantine: $_\n" ] } qw(on off OFF no 0 false disabled yes true) ),
    [ 'a threshold of three', "spam_url_threshold: 3\n" ],
    [ 'a threshold of zero',  "spam_url_threshold: 0\n" ],
    )
{
    my ( $label, $conf ) = @$case;
    my $handler = held_by_handler($conf);
    my $state   = Lazysite::Handlers::form_quarantine_state( "targets:\n  - handler: jsonl\n$conf" );
    ok( defined $handler, "$label: the handler stored the submission" ) or next;

    # The manager says "on" and the threshold; held means on AND two links reached it.
    my $predicted = ( $state->{on} && $state->{url_threshold} > 0 && 2 >= $state->{url_threshold} ) ? 1 : 0;
    is( $predicted, $handler, "$label: the manager's reading predicts what the handler did" )
        or diag( 'manager: on=' . ( $state->{on} ? 1 : 0 ) . " threshold=$state->{url_threshold}; handler held=$handler" );
}

is( Lazysite::Handlers::form_quarantine_state("spam_keywords: casino, loans , \n")->{keywords}, 2,
    'keywords are counted as the handler splits them' );
ok( !Lazysite::Handlers::form_quarantine_state('')->{own_domain}, 'the own-domain signal is off by default (SM930)' );
ok( Lazysite::Handlers::form_quarantine_state("spam_own_domain: on\n")->{own_domain}, 'and on when the form says so' );

subtest 'the Handlers page words it from that reading' => sub {
    # The page's own functions, run in node: what an operator reads for a form
    # with quarantine on, and one with it off.
    chomp( my $node = `sh -c 'command -v node || command -v nodejs' 2>/dev/null` );
    plan skip_all => 'node not installed' unless length $node;
    my $page = page_source( repo_root() . '/starter/manager/handlers.md' );
    my $defs = join "\n", map { extract_function( $page, $_, 'handlers.md' ) }
        qw(escHtml quarantineLine quarantineDetail);
    my $js = "var QUARANTINE = " . JSON::PP->new->canonical->encode( {
            open   => Lazysite::Handlers::form_quarantine_state("spam_keywords: casino\n"),
            closed => Lazysite::Handlers::form_quarantine_state("quarantine: off\n") } ) . ";\n"
        . $defs . "\nconsole.log(JSON.stringify({ ol: quarantineLine('open'), cl: quarantineLine('closed'),"
        . " od: quarantineDetail('open'), cd: quarantineDetail('closed') }));\n";
    my $tmp = "$d/q.js";
    spit( $tmp, $js );
    my $raw = `\Q$node\E \Q$tmp\E 2>&1`;
    my $r   = eval { decode_json($raw) } or return fail("the page functions did not run: $raw");
    is( $r->{ol}, 'quarantine on',  'the row says on' );
    is( $r->{cl}, 'quarantine off', 'and off' );
    like( $r->{od}, qr/2 or more links.*a link shortener.*1 keyword/, 'the detail names what holds a submission' );
    like( $r->{cd}, qr/delivered and announced like any other/, 'and what off means' );
};

done_testing();
