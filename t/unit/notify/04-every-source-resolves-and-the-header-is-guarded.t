#!/usr/bin/perl
# SM1020 (SM1010 phase 1): THE OTHER RECIPIENT SOURCES, AND WHAT THE ENGINE
# GUARDS ON THE WIRE.
#
# The ruling made recipients the operator's decision - "addresses loaded into the
# database" included - and the engine's job technical safety. So: addresses held
# in a table are sent to, one message each; a row whose address names two
# recipients is refused and audited, never split or repaired; the submitter's
# own field reaches them; the commenter's own address is left out of an address
# source too. And the header writer encodes a non-ASCII Subject (RFC 2047) and
# carries only the headers it knows, in their own shape.
use strict;
use warnings;
use utf8;
use Test::More;
use File::Path qw(make_path);
use JSON::PP   ();
use FindBin;
use lib "$FindBin::Bin/../../lib", "$FindBin::Bin/../../../lib";
use TestHelper             qw(repo_root site_tempdir run_cmd run_child);
use Lazysite::Handlers     ();
use Lazysite::Outbox       ();
use Lazysite::Mail         ();
use Lazysite::Data::Tables qw(apply_schema insert_row);

my $root = repo_root();
sub spit { my ( $p, $t ) = @_; open my $fh, '>:utf8', $p or die "$p: $!"; print {$fh} $t; close $fh; return }
sub slurp { my ($p) = @_; open my $fh, '<:raw', $p or return ''; local $/; my $t = <$fh>; close $fh; return $t // '' }

my $d = site_tempdir();
make_path( "$d/lazysite/forms", "$d/lazysite/logs", "$d/lazysite/db/tables" );
spit( "$d/lazysite/lazysite.conf", "site_name: T\nsite_url: https://news.example\nplugins:\n  - plugins/data.pl\n" );
my $OUT = "$d/mail.out";
spit( "$d/sendmail", "#!$^X\nopen my \$w, '>>', '$OUT' or exit 1; local \$/; print {\$w} \"--MESSAGE--\\n\", <STDIN>; close \$w;\n" );
chmod 0755, "$d/sendmail";
spit( "$d/lazysite/forms/smtp.conf", "method: sendmail\nsendmail_path: $d/sendmail\n" );
spit( "$d/lazysite/db/tables/members.yaml",
    "title: Members\nfields:\n  email:\n    type: text\n  list:\n    type: text\n" );
spit( "$d/lazysite/forms/handlers.conf",
    "handlers:\n  - id: newsletter\n    type: notify\n    name: Newsletter\n"
        . '    recipients: [{"addresses_from":{"table":"members","column":"email","where":{"list":"list"}}},'
        . '{"submitter":{"field":"reply_to"}}]' . "\n"
        . "    unsubscribe_path: /lists\n" );
run_cmd( $^X, "$root/tools/lazysite-users.pl", '--docroot', $d, 'add', 'zz9member', 'pw-123456789' );
run_cmd( $^X, "$root/tools/lazysite-users.pl", '--docroot', $d, 'set', 'zz9member', 'email', 'me@example.net' );
$Lazysite::Handlers::DOCROOT = $d;
apply_schema( $d, 'members' );
insert_row( $d, 'members', { email => $_->[0], list => $_->[1] }, actor => 'op' )
    for [ 'a@example.net', 'weekly' ], [ 'root,b@example.org', 'weekly' ], [ 'me@example.net', 'weekly' ],
    [ 'c@example.net', 'monthly' ];

sub messages { return grep { length } split /--MESSAGE--\n/, slurp($OUT) }
sub to_list  { return sort { $a cmp $b } map { /^To: (\S+)/m ? $1 : '?' } messages() }

subtest 'addresses from a table, and the submitter\'s field' => sub {
    my $r = Lazysite::Handlers::deliver( 'newsletter', { list => 'weekly', reply_to => 'reader@example.org' },
        origin => 'form', source => 'form:join', actor => 'zz9member' );
    ok( $r->{queued}, 'queued' ) or diag explain $r;
    my $j = Lazysite::Outbox::run( docroot => $d, actor => 'jobs' );
    ok( $j->{ok}, 'ran' ) or diag explain $j;
    is_deeply( [ to_list() ], [qw(a@example.net reader@example.org)],
        'the weekly list and the submitter - not the monthly row, not the commenter\'s own address, '
            . 'and not the row naming two recipients' );
    my $audit = slurp("$d/lazysite/logs/audit.log");
    like( $audit, qr/failed \| daemon \| address root,b\@example\.org - refused: it is not exactly one address/,
        'the two-recipient row is a failed audit row, refused - not split, not repaired' );
};

subtest 'RFC 2047: a Subject that is not ASCII is encoded, and ASCII is left alone' => sub {
    is( Lazysite::Mail::encode_header('Plain subject'), 'Plain subject', 'ASCII unchanged' );
    my $e = Lazysite::Mail::encode_header( 'Café — ' . ( 'é' x 40 ) );
    unlike( $e, qr/[^\x00-\x7f]/, 'all ASCII on the wire' );
    my @words = $e =~ /=\?UTF-8\?B\?([^?]+)\?=/g;
    cmp_ok( scalar @words, '>', 1, 'a long value is several encoded words' );
    ok( !( grep { length("=?UTF-8?B?$_?=") > 75 } @words ), 'each at most 75 characters' );
    require MIME::Base64;
    my $back = join '', map { MIME::Base64::decode_base64($_) } @words;
    utf8::decode($back);
    is( $back, 'Café — ' . ( 'é' x 40 ), 'and they decode, whole characters each, to the value' );
    unlike( Lazysite::Mail::encode_header("a\r\nBcc: x\@y"), qr/[\r\n](?! )/, 'no line break but a fold' );
};

subtest 'the message mode carries only the headers it knows, in their shape' => sub {
    my $script = "$root/plugins/form-smtp.pl";
    my $send   = sub {
        my ($headers) = @_;
        local $ENV{DOCUMENT_ROOT} = $d;
        my $res = run_child( [ $^X, $script, '--pipe' ], stderr => 'inherit',
            stdin => JSON::PP::encode_json( { config => { to => 'x@example.net' }, form => {},
                message => { subject => 's', text => 't', headers => $headers } } ) )->{out};
        return JSON::PP::decode_json($res);
    };
    unlink $OUT;
    ok( $send->( { 'List-Unsubscribe' => '<https://news.example/lists>',
                'List-Unsubscribe-Post' => 'List-Unsubscribe=One-Click' } )->{ok},
        'a well-formed pair is sent (SM1073: RFC 8058\'s Post header too)' );
    for my $bad ( { 'Bcc' => 'y@example.org' }, { 'List-Unsubscribe' => "<https://x>\nBcc: y\@example.org" },
        { 'List-Unsubscribe' => 'mailto:y@example.org' },
        { 'List-Unsubscribe-Post' => "List-Unsubscribe=One-Click\nBcc: y\@example.org" },
        { 'List-Unsubscribe-Post' => 'List-Unsubscribe=Everything' } )
    {
        my ($k) = keys %$bad;
        my $r = $send->($bad);
        ok( !$r->{ok}, "refused: $k" );
    }
    is( scalar( () = messages() ), 1, 'and only the good one reached sendmail' );
};

done_testing();
