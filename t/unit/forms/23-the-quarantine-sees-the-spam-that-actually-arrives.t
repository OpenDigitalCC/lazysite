#!/usr/bin/perl
# SM913 S1 and S3: the two signals that would have caught the spam a live form
# took for two months.
#
# Four of four genuine-looking submissions on opendigital.cc's contact form were
# spam, read one by one by the crm-agent, each from a different source range - so
# nothing about addresses would have caught any of them. SM216's quarantine was
# built for exactly this and did not fire, and the reason is in one line:
#
#     my $urls = () = $text =~ m{https?://}gi;
#
# The count wanted a SCHEME. The reported pitches wrote their opt-out host as
# `brnd .li/delist`, with a space inserted to defeat link filters - which is the
# one marker present in all three of them, and invisible to that pattern. The
# fourth was gibberish carrying the same 7-digit number in every field, which no
# URL rule will ever see.
#
# THE FIXTURES ARE BUILT FROM THE REPORTER'S DESCRIPTION, not from the four
# stored records. Those hold real senders' addresses; the description named every
# marker precisely enough to reconstruct the shapes, and a test does not need
# somebody's mail address to prove a signal works.
#
# HALF THIS FILE IS THE HONEST SUBMISSIONS, and that is the point. A quarantine
# costs nothing when it is wrong - the message still arrives, just unannounced -
# but only while it is wrong RARELY. A signal that flags an enquiry naming its
# own attachment, or the sender's own email domain, would be worse than none.
use strict;
use warnings;
use Test::More;
use JSON::PP    qw(decode_json);
use Digest::SHA qw(hmac_sha256_hex);
use File::Path  qw(make_path);
use FindBin;
use lib "$FindBin::Bin/../../lib";
use TestHelper qw(repo_root site_tempdir);

my $PLUGIN = repo_root() . '/plugins/form-handler.pl';
plan skip_all => "no $PLUGIN" unless -f $PLUGIN;

my $d = site_tempdir();
make_path( "$d/lazysite/forms", "$d/subs" );
my $SECRET = 'test-secret-1234567890';

sub spit { my ( $p, $t ) = @_; open my $fh, '>', $p or die "$p: $!"; print {$fh} $t; close $fh; return }

spit( "$d/lazysite/forms/.secret",       "$SECRET\n" );
spit( "$d/lazysite/lazysite.conf",       "site_name: T\n" );
spit( "$d/lazysite/forms/handlers.conf",
    "handlers:\n  - id: jsonl\n    type: file\n    name: Local\n    path: $d/subs\n" );
# quarantine is not named, so this is the DEFAULT behaviour being tested.
spit( "$d/lazysite/forms/contact.conf", "targets:\n  - handler: jsonl\n" );

my $BOUNDARY = 'Sbnd913';

# Returns the stored submission for one POST of %fields.
#
# EACH POST COMES FROM A DIFFERENT ADDRESS, and not for realism: the form's own
# rate limit is five an hour per source IP, so a file with more than five cases
# would silently stop storing them and every later assertion would fail for a
# reason that has nothing to do with the thing under test. (It is also a neat
# demonstration of why that limiter is the wrong axis for an open relay, which is
# the argument SM877 turned on.)
my $ip = 0;

sub submit {
    my (%fields) = @_;
    unlink "$d/subs/contact.jsonl";
    $ip++;

    my $ts = time() - 10;
    my $body = '';
    for my $pair ( [ '_form', 'contact' ], [ '_ts', $ts ],
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
    local $ENV{REMOTE_ADDR}    = "10.0.0.$ip";
    qx($^X \Q$PLUGIN\E < \Q$in\E 2>/dev/null);

    open my $fh, '<', "$d/subs/contact.jsonl" or return undef;
    my @lines = <$fh>;
    close $fh;
    return undef unless @lines;
    return decode_json( $lines[-1] );
}

subtest 'the three reported spam shapes are all quarantined' => sub {
    my $footer = submit(
        name    => 'Ben Fisher',
        email   => 'benfisher821@hotmail.com',
        subject => 'Restore your website from the web archive - full recovery service',
        message => "We rebuild any site from archive snapshots. Examples at brnd .li/portfolio. "
            . "To opt out, fill the form at brnd .li/delist with your domain address (URL). "
            . '1209 Fake Street, Springfield, CA, USA, 90210',
    );
    ok( $footer, 'the submission was stored' ) or return;
    ok( $footer->{_quarantined}, 'Kind A - the spaced shortener is seen' )
        or diag( 'This is the marker present in all three sales pitches, and '
            . 'the one the scheme-only count could not see.' );
    like( $footer->{_spam_reason}, qr/a link written as 'brnd\.li'/,
        'named as the disguise it is, not as a link count' )
        or diag( 'Counting was not enough: BOTH links in the reported message '
            . 'are the same host, and the counter deduplicates by host - which '
            . 'is right, and is why the disguise has to be its own reason.' );

    my $www = submit(
        name    => 'SEO Team',
        email   => 'seo.offers@gmail.com',
        subject => 'Backlinks that actually rank - limited slots',
        message => 'Packages at www.rank-fast-now.biz and details on brnd .li/seo',
    );
    ok( $www->{_quarantined}, 'Kind A - a www host and a shortener' );

    # Nothing above this makes the WIDENED COUNTING load-bearing: both pitches
    # carry the disguised host, which is its own reason. Two distinct hosts
    # written without a scheme, and no disguise - so if the count went back to
    # wanting `https://`, this is the case that notices.
    my $scheme_less = submit(
        name    => 'Growth',
        email   => 'growth@gmail.com',
        subject => 'Can I run it - game checker partnership',
        message => 'Our checker is at www.can-i-run-it-fast.biz and the reviews '
            . 'are on gamer-reviews-hub.info/partners - interested?',
    );
    ok( $scheme_less->{_quarantined},
        'two hosts written without a scheme are two links' )
        or diag( 'The old count wanted https:// and would have seen neither.' );

    my $gibberish = submit(
        name    => 'KJHFWEIU 4829173',
        email   => 'zxq4829173@mailinator.com',
        subject => 'PQWOEIRU 4829173',
        message => 'MNBVCXZ 4829173 LKJHGF',
    );
    ok( $gibberish->{_quarantined}, 'Kind B - one number in every field' )
        or diag('No URL rule will ever see this one.');
    like( $gibberish->{_spam_reason}, qr/4829173 is in every field/,
        'and the reason says which number' );
};

subtest 'honest submissions are left alone' => sub {
    my %cases = (
        'an ordinary enquiry' => {
            name    => 'Ada Lovelace',
            email   => 'ada@example.net',
            message => 'Could you send me a quote for a five-page site? Thank you.',
        },
        'one that names the files it attached' => {
            name    => 'Herve Dupont',
            email   => 'herve@example.org',
            subject => 'Logo files',
            message => 'I have attached logo.png and the brief as brief.pdf - and photo.jpg.',
        },
        'one that quotes a single page of ours' => {
            name    => 'Sam',
            email   => 'sam@example.co.uk',
            subject => 'Question about a page',
            message => 'I read https://example.com/pricing and had a question about it.',
        },
        'a developer writing about tools and versions' => {
            name    => 'Dev',
            email   => 'dev@example.net',
            subject => 'Node.js and version 1.2.3',
            message => 'We run Node.js 20 and our config is version 1.2.3 - compatible?',
        },
        'a reference number in two fields of three' => {
            name    => 'Ada Lovelace',
            subject => 'Order 4829173',
            message => 'My order 4829173 has not arrived - could you check?',
        },
        'a two-field form whose fields repeat' => {
            name    => 'Ada',
            message => 'Ada',
        },
    );

    for my $label ( sort keys %cases ) {
        my $r = submit( %{ $cases{$label} } );
        ok( $r, "$label: stored" ) or next;
        ok( !$r->{_quarantined}, "$label: NOT quarantined" )
            or diag( "reason given: " . ( $r->{_spam_reason} // '(none)' ) );
    }
};

subtest 'the address in an email field is not a link' => sub {
    # The one false positive that would have made this unshippable: a form with
    # an email field would score a host on every honest submission.
    my $r = submit(
        name    => 'Ada',
        email   => 'ada@example.net',
        message => 'Please reply to ada@example.net or ada@example.org, whichever suits.',
    );
    ok( !$r->{_quarantined}, 'two addresses and no links is not two links' )
        or diag( 'reason: ' . ( $r->{_spam_reason} // '' ) );
};

subtest 'one host written two ways is one link' => sub {
    my $r = submit(
        name    => 'Ada',
        message => 'See https://shop.example.com/x - also linked as www.shop.example.com.',
    );
    ok( !$r->{_quarantined},
        'the same host counted once does not reach a threshold of two' )
        or diag( 'reason: ' . ( $r->{_spam_reason} // '' )
            . ' - a person naming one site two ways is not two links' );
};

subtest 'a space before a full stop is not a disguised link' => sub {
    # The false positive the path requirement exists to prevent. Sloppy typing
    # produces this; nothing honest produces `host .tld/path`.
    my $r = submit(
        name    => 'Ada',
        subject => 'Visit',
        message => 'I came by the shop .Then I left again, sorry to miss you.',
    );
    ok( !$r->{_quarantined}, 'a stray space before a sentence break is left alone' )
        or diag( 'reason: ' . ( $r->{_spam_reason} // '' ) );
};

done_testing();
