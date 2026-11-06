#!/usr/bin/perl
# SM1379 (ruling 133, triage T-34): the quarantine's "one value everywhere" rule
# leaves email fields out, and an email field holding quotes or SQL is
# quarantined.
#
# SM913 S3 counted every field, the email field included, so a bot that put
# its number in name, subject and message and a RANDOM ADDRESS in the email
# field broke the rule: the address differed and did not carry the number.
# And an email field is where a scanner puts its payload; a form with no rules
# sidecar has no `type: email` check to refuse it.
#
# Quarantined, never refused (SM913): each case below is STORED, and the
# assertion is on `_quarantined` and `_spam_reason`. The fixtures are built
# shapes, not real submissions.
use strict;
use warnings;
use Test::More;
use JSON::PP    qw(decode_json);
use Digest::SHA qw(hmac_sha256_hex);
use File::Path  qw(make_path);
use FindBin;
use lib "$FindBin::Bin/../../lib";
use TestHelper qw(repo_root site_tempdir);

my $EXTENSION = repo_root() . '/extensions/form-handler.pl';
plan skip_all => "no $EXTENSION" unless -f $EXTENSION;

my $d = site_tempdir();
make_path( "$d/lazysite/forms", "$d/subs" );
my $SECRET = 'test-secret-1234567890';

sub spit { my ( $p, $t ) = @_; open my $fh, '>', $p or die "$p: $!"; print {$fh} $t; close $fh; return }

spit( "$d/lazysite/forms/.secret", "$SECRET\n" );
spit( "$d/lazysite/lazysite.conf", "site_name: T\n" );
spit( "$d/lazysite/forms/handlers.conf",
    "handlers:\n  - id: jsonl\n    type: file\n    name: Local\n    path: $d/subs\n" );
spit( "$d/lazysite/forms/contact.conf",  "targets:\n  - handler: jsonl\n" );
spit( "$d/lazysite/forms/declared.conf", "targets:\n  - handler: jsonl\n" );
# A field the page declared `type: email` under a name that does not say so.
spit( "$d/lazysite/forms/declared.rules",
    '{"fields":[{"name":"contact","type":"email"},{"name":"message"}]}' . "\n" );

my $BOUNDARY = 'Sbnd1379';
my $ip       = 0;    # one source address per post: the form's rate limit is per IP

sub submit {
    my ( $form, %fields ) = @_;
    unlink "$d/subs/$form.jsonl";
    $ip++;
    my $ts   = time() - 10;
    my $body = '';
    for my $pair ( [ '_form', $form ], [ '_ts', $ts ],
        [ '_tk', hmac_sha256_hex( $ts, $SECRET ) ], [ '_hp', '' ],
        map { [ $_, $fields{$_} ] } sort keys %fields )
    {
        $body .= "--$BOUNDARY\r\nContent-Disposition: form-data; name=\"$pair->[0]\"\r\n\r\n$pair->[1]\r\n";
    }
    $body .= "--$BOUNDARY--\r\n";
    my $in = "$d/post.bin";
    spit( $in, $body );

    local $ENV{REQUEST_METHOD} = 'POST';
    local $ENV{CONTENT_TYPE}   = "multipart/form-data; boundary=$BOUNDARY";
    local $ENV{CONTENT_LENGTH} = length $body;
    local $ENV{DOCUMENT_ROOT}  = $d;
    local $ENV{REMOTE_ADDR}    = "10.13.79.$ip";
    qx($^X \Q$EXTENSION\E < \Q$in\E 2>/dev/null);

    open my $fh, '<', "$d/subs/$form.jsonl" or return undef;
    my @lines = <$fh>;
    close $fh;
    return @lines ? decode_json( $lines[-1] ) : undef;
}

subtest 'a random address no longer hides one value said three times' => sub {
    my $r = submit( 'contact',
        name    => 'KJHFWEIU 4829173',
        email   => 'qpwoeiruty@example.net',
        subject => 'PQWOEIRU 4829173',
        message => 'MNBVCXZ 4829173 LKJHGF',
    );
    ok( $r, 'stored' ) or return;
    ok( $r->{_quarantined}, 'the number in every OTHER field is seen' );
    like( $r->{_spam_reason} // '', qr/4829173 is in every field/, 'and named' );

    $r = submit( 'contact',
        name    => 'ASDFGHJKL',
        email   => 'zmxncbv@example.org',
        subject => 'asdfghjkl',
        message => 'ASDFGHJKL!',
    );
    ok( $r->{_quarantined}, 'one text in every field but the address' );
    like( $r->{_spam_reason} // '', qr/every field holds the same value/, 'and named' );

    # An address under a name that does not say email is still an address.
    $r = submit( 'contact',
        name     => 'ASDFGHJKL',
        reply_to => 'zmxncbv@example.org',
        subject  => 'asdfghjkl',
        message  => 'ASDFGHJKL',
    );
    ok( $r->{_quarantined}, 'a field holding only an address is left out too' );
};

subtest 'leaving the address out does not make a short form look repeated' => sub {
    my $r = submit( 'contact',
        name    => 'Ada',
        email   => 'ada@example.net',
        message => 'Ada',
    );
    ok( $r, 'stored' ) or return;
    ok( !$r->{_quarantined}, 'two fields that repeat are still two, not three' )
        or diag( $r->{_spam_reason} );
};

subtest 'an email field holding quotes or SQL is quarantined' => sub {
    my %probes = (
        'a quoted tautology'      => q{x' OR 1=1--},
        'a stacked statement'     => 'a@example.com; DROP TABLE users',
        'a union probe'           => '1 UNION SELECT password FROM users',
        'a double quote'          => 'a"b@example.com',
        'a comment opener'        => 'a@example.com/*',
        'a timing probe'          => 'a@example.com AND SLEEP(5)',
    );
    for my $case ( sort keys %probes ) {
        my $r = submit( 'contact',
            name    => 'Ada Lovelace',
            email   => $probes{$case},
            message => 'Could you send me a quote, please?',
        );
        ok( $r, "$case: stored, never refused" ) or next;
        ok( $r->{_quarantined}, "$case: quarantined" );
        like( $r->{_spam_reason} // '', qr/the email field 'email' holds quotes or SQL/,
            "$case: the reason names the field" );
        unlike( $r->{_spam_reason} // '', qr/\Q$probes{$case}\E/,
            "$case: and does not repeat the probe" );
    }

    my $r = submit( 'contact',
        name         => 'Ada',
        'your-email' => q{' or '1'='1},
        message      => 'Hello there, a question about pricing.',
    );
    ok( $r->{_quarantined}, 'a field named for email, under another spelling' );

    $r = submit( 'declared',
        contact => q{o'x@example.com},
        message => 'Hello there, a question about pricing.',
    );
    ok( $r, 'a declared type=email field with a quote passes the shape check' ) or return;
    like( $r->{_spam_reason} // '', qr/the email field 'contact'/,
        'and is quarantined: what the declaration lets through is address-shaped' );
};

subtest 'ordinary addresses are left alone' => sub {
    for my $addr ( 'ada@example.net', 'ada.lovelace+forms@example.co.uk', 'a_b-c@sub.example.org' ) {
        my $r = submit( 'contact',
            name    => 'Ada Lovelace',
            email   => $addr,
            message => 'Could you send me a quote for a five-page site? Thank you.',
        );
        ok( $r && !$r->{_quarantined}, "$addr is not quarantined" )
            or diag( $r ? $r->{_spam_reason} : 'not stored' );
    }
    # The rule reads EMAIL fields: a message may say select ... from, or quote.
    my $r = submit( 'contact',
        name    => 'Dev',
        email   => 'dev@example.net',
        message => q{Can I select a plan from your list? It's "urgent"; thanks -- Dev},
    );
    ok( $r && !$r->{_quarantined}, 'quotes and SQL words in the MESSAGE are not this rule' )
        or diag( $r ? $r->{_spam_reason} : 'not stored' );
};

subtest 'the Handlers page lists the new signal' => sub {
    # SM913 S4: each form's row says what holds a submission. A signal the page
    # does not name is one an operator cannot tell is on.
    open my $fh, '<', repo_root() . '/starter/manager/handlers.md' or die $!;
    my $page = do { local $/; <$fh> };
    close $fh;
    like( $page, qr/'quotes or SQL in an email field'/, 'named among the reasons' );
};

done_testing();
