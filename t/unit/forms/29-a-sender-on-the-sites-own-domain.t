#!/usr/bin/perl
# SM930: a sender on the site's own domain is a forgery signal - OFF BY DEFAULT.
#
# The site owner found it. Of six spam submissions to their site, one gave its
# sender address as someone@<that site's own domain>; simulated against the nine
# stored submissions it quarantined 6 of 6 junk and delivered 3 of 3 genuine, and it
# was the only signal that caught number four on its own.
#
# RULED 2026-10-01: shipped as a heuristic, off by default, behind `spam_own_domain`
# - because a form that genuinely IS for internal use would start quarantining its
# real traffic the day it was upgraded, and because the engine cannot tell an
# authenticated submission from an anonymous one (a stored submission carries no
# actor at all, SM402/SM924), so the rule would also catch a staff member testing
# the form from their own desk.
#
# HALF THIS FILE IS THE SUBMISSIONS THAT MUST STILL ARRIVE. A quarantine costs
# nothing when it is wrong only while it is wrong RARELY, and the two false
# positives this heuristic could plausibly cause are both asserted against:
#   - a customer who MENTIONS the site's own address in their message ("I wrote to
#     info@... and heard nothing") - the shape a frustrated enquiry takes;
#   - a stranger on a domain that merely ENDS with the site's, which is the
#     substring trap feedback_substring_matching_false_positives names.
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

spit( "$d/lazysite/forms/.secret", "$SECRET\n" );
spit( "$d/lazysite/forms/handlers.conf",
    "handlers:\n  - id: jsonl\n    type: file\n    name: Local\n    path: $d/subs\n" );

sub set_site_url { spit( "$d/lazysite/lazysite.conf", "site_name: T\nsite_url: $_[0]\n" ) }
sub own_domain_on { spit( "$d/lazysite/forms/contact.conf",
        "targets:\n  - handler: jsonl\nspam_own_domain: " . $_[0] . "\n" ) }

my $BOUNDARY = 'Sbnd930';

# A different source address per POST: the form's own rate limit is five an hour
# per address, so a file with more cases than that would silently stop storing and
# every later assertion would fail for a reason unrelated to the thing under test.
my $ip = 0;

sub submit {
    my (%fields) = @_;
    unlink "$d/subs/contact.jsonl";
    $ip++;

    my $ts   = time() - 10;
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
    local $ENV{REMOTE_ADDR}    = "203.0.113.$ip";
    local $ENV{HTTP_HOST}      = 'www.example.com';
    qx($^X \Q$PLUGIN\E < \Q$in\E 2>/dev/null);

    open my $fh, '<', "$d/subs/contact.jsonl" or return undef;
    my @lines = <$fh>;
    close $fh;
    return undef unless @lines;
    return decode_json( $lines[-1] );
}

# --- OFF BY DEFAULT, which is the ruling and not a detail --------------------
subtest 'a form that never asks for this keeps delivering own-domain senders' => sub {
    set_site_url('https://example.com');
    spit( "$d/lazysite/forms/contact.conf", "targets:\n  - handler: jsonl\n" );
    my $r = submit(
        name    => 'Posture Corrector',
        email   => 'sales@example.com',
        message => 'Best posture corrector, 50% off this week.',
    );
    ok( $r, 'the submission was stored' ) or return;
    ok( !$r->{_quarantined},
        'not quarantined: the key was never named, so nothing changed on upgrade' )
        or diag( 'A form that genuinely is for internal use must not start '
            . 'quarantining its own traffic because the engine was upgraded.' );
};

subtest 'and the same submission IS quarantined once the site asks' => sub {
    set_site_url('https://example.com');
    own_domain_on('on');
    my $r = submit(
        name    => 'Posture Corrector',
        email   => 'sales@example.com',
        message => 'Best posture corrector, 50% off this week.',
    );
    ok( $r,                 'the submission was stored' ) or return;
    ok( $r->{_quarantined}, 'quarantined' );
    like( $r->{_spam_reason}, qr/sender claims an address at this site's own domain/,
        'and the reason says which signal fired, in the voice of the other three' );
};

# --- THE TWO FALSE POSITIVES IT MUST NOT CAUSE ------------------------------
subtest 'a domain that merely ENDS with the site\'s is somebody else' => sub {
    set_site_url('https://example.com');
    own_domain_on('on');
    my $r = submit(
        name    => 'Jane Okafor',
        email   => 'jane@notexample.com',
        message => 'Could you send me a quote for twelve units?',
    );
    ok( $r, 'the submission was stored' ) or return;
    ok( !$r->{_quarantined},
        'delivered: notexample.com is a different organisation' )
        or diag( 'A suffix match on the domain is the trap '
            . 'feedback_substring_matching_false_positives exists for.' );
};

subtest 'a customer who MENTIONS the site address is a genuine enquiry' => sub {
    set_site_url('https://example.com');
    own_domain_on('on');
    my $r = submit(
        name    => 'Tom Beresford',
        email   => 'tom.beresford@somecouncil.gov.uk',
        message => 'I wrote to info@example.com last week and heard nothing. '
            . 'Can somebody call me about the order?',
    );
    ok( $r, 'the submission was stored' ) or return;
    ok( !$r->{_quarantined},
        'delivered: the rule reads the FIELD, not an address inside a sentence' )
        or diag( 'This is the shape a frustrated customer writes, and the sender '
            . 'would never learn their message had been set aside.' );
};

# --- what it does catch -----------------------------------------------------
subtest 'a subdomain of the site\'s own domain is still the site' => sub {
    set_site_url('https://example.com');
    own_domain_on('on');
    my $r = submit(
        name    => 'Billing',
        email   => 'accounts@mail.example.com',
        message => 'Your invoice is attached.',
    );
    ok( $r,                 'the submission was stored' ) or return;
    ok( $r->{_quarantined}, 'quarantined on a label boundary' );
};

subtest 'the host the request arrived on is a source too' => sub {
    # No site_url at all: the only thing the site knows is the presented host,
    # which SM926 ruled IS the host. www. is stripped, so a sender at the bare
    # domain still matches.
    spit( "$d/lazysite/lazysite.conf", "site_name: T\n" );
    own_domain_on('on');
    my $r = submit(
        name    => 'Nobody',
        email   => 'ceo@example.com',
        message => 'Please pay this invoice today.',
    );
    ok( $r, 'the submission was stored' ) or return;
    ok( $r->{_quarantined},
        'quarantined from HTTP_HOST alone, with www. stripped' );
};

subtest 'an ordinary outside enquiry is untouched' => sub {
    set_site_url('https://example.com');
    own_domain_on('on');
    my $r = submit(
        name    => 'Dr Ama Mensah',
        email   => 'a.mensah@someuniversity.edu',
        message => 'We are evaluating your product for a research group of eight.',
    );
    ok( $r,                  'the submission was stored' ) or return;
    ok( !$r->{_quarantined}, 'delivered' );
};

done_testing();
