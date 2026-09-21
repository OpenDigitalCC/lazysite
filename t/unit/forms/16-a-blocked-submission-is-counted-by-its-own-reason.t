#!/usr/bin/perl
# SM888 A7, second half: a blocked submission is COUNTED, under the reason of
# the control that blocked it.
#
# WHAT THIS IS ABOUT, AND WHY IT IS A SEPARATE FILE FROM t/unit/forms/15.
# That file holds what the VISITOR is told. This holds what the SYSOP is
# told - and the first half of A7 broke the second half while fixing the first.
#
# `_block_reason` recovered the reason code by matching the refusal's PROSE:
#
#     return 'too_fast' if $err =~ /Submission too fast/;
#     return 'expired'  if $err =~ /Submission expired/;
#
# A7 reworded both of those messages so a real person could read them, and left
# the matcher looking for words that then existed nowhere in the tree. An
# unmatched refusal returns '', the caller reads '' as "not an anti-spam
# control", and records NOTHING - not even a blocked line with an empty reason,
# which `plugins/stats.pl` would at least have bucketed as `other`. So the
# report's "controls stopped N" quietly lost two of its five reasons.
#
# REPRODUCED before it was fixed, against this same handler: a POST inside the
# three-second floor produced the new message, the correct refusal, and
# `(no form-events directory at all)`. A successful POST in the same run wrote
# its `stored` line, so the recorder was working and only the classification was
# not.
#
# NOTHING CAUGHT IT. No test in the suite named `_block_reason` or any of the
# five reason codes. That is what this file is for, and it is written to measure
# the property rather than the mechanism: each control is driven for real and
# the day-bucket is read off disk. The reason code now travels WITH the refusal,
# so rewording a message cannot break it - but a NEW control added without a
# code would go uncounted, and the roll-call at the bottom is what says so.
use strict;
use warnings;
use Test::More;
use File::Path  qw(make_path);
use Digest::SHA qw(hmac_sha256_hex);
use JSON::PP    qw(decode_json);
use FindBin;
use lib "$FindBin::Bin/../../lib";
use TestHelper qw(repo_root env_passthrough site_tempdir);

my $root    = repo_root();
my $handler = "$root/plugins/form-handler.pl";
plan skip_all => "no $handler" unless -f $handler;
my $SECRET = 'b' x 64;

# A FRESH SITE PER CASE. The events file is append-only by design, so a shared
# docroot would let one case read another's line and pass on it - which is the
# kind of accident that makes a counting test agree with whatever it is given.
sub site {
    my (%o) = @_;
    my $docroot = site_tempdir();
    make_path("$docroot/lazysite/forms");
    make_path("$docroot/lazysite/auth");
    open my $cf, '>', "$docroot/lazysite/lazysite.conf" or die $!;
    print {$cf} "site_name: T\n";
    close $cf;
    open my $hcf, '>', "$docroot/lazysite/forms/handlers.conf" or die $!;
    print {$hcf} "handlers:\n  - id: store\n    type: file\n    name: Store\n";
    close $hcf;
    open my $ff, '>', "$docroot/lazysite/forms/contact.conf" or die $!;
    print {$ff} 'rate_limit: ' . ( defined $o{rate_limit} ? $o{rate_limit} : 0 )
        . "\ntargets:\n  - handler: store\n";
    close $ff;
    open my $fs, '>', "$docroot/lazysite/forms/.secret" or die $!;
    print {$fs} $SECRET;
    close $fs;
    return $docroot;
}

sub submit {
    my ( $docroot, %o ) = @_;
    my $ts = defined $o{ts} ? $o{ts} : time - 10;
    my $tk = defined $o{tk} ? $o{tk} : hmac_sha256_hex( $ts, $SECRET );
    my %f = ( _form => ( defined $o{form} ? $o{form} : 'contact' ),
        name => 'x', _hp => ( defined $o{hp} ? $o{hp} : '' ), _ts => $ts, _tk => $tk );
    my $body = join '&', map { "$_=$f{$_}" } sort keys %f;
    my $bf = "$docroot/.body";
    open my $b, '>', $bf or die $!;
    print {$b} $body;
    close $b;
    local %ENV = ( env_passthrough(),
        DOCUMENT_ROOT  => $docroot,
        REQUEST_METHOD => ( defined $o{method} ? $o{method} : 'POST' ),
        CONTENT_TYPE   => 'application/x-www-form-urlencoded',
        CONTENT_LENGTH => length $body,
        REMOTE_ADDR    => '203.0.113.9',
        HTTP_ACCEPT    => 'application/json',
    );
    return qx($^X \Q$handler\E < \Q$bf\E 2>/dev/null) // '';
}

# Every recorded event for the site, newest last, as the stats reader sees them.
sub events {
    my ($docroot) = @_;
    my $dir = "$docroot/lazysite/stats/form-events";
    return () unless -d $dir;
    my @rows;
    opendir my $dh, $dir or return ();
    for my $f ( sort grep { !/^\./ } readdir $dh ) {
        open my $r, '<', "$dir/$f" or next;
        while ( my $l = <$r> ) {
            chomp $l;
            next unless length $l;
            my $row = eval { decode_json($l) };
            push @rows, $row if $row;
        }
        close $r;
    }
    closedir $dh;
    return @rows;
}

# --- the control cases, one per reason code ---------------------------------

my @CASES = (
    {   reason => 'too_fast',
        what   => 'posted inside the three-second floor',
        run    => sub { submit( $_[0], ts => time ) },
        # This one and `expired` are the two the reword broke. If either of
        # these subtests fails, the classification has gone back to reading
        # prose.
    },
    {   reason => 'expired',
        what   => 'posted from a page left open past the window',
        run    => sub { submit( $_[0], ts => time - 100_000 ) },
    },
    {   reason => 'honeypot',
        what   => 'the hidden field was filled in',
        run    => sub { submit( $_[0], hp => 'bot' ) },
    },
    {   reason => 'token',
        what   => 'the HMAC did not match',
        run    => sub { submit( $_[0], tk => 'f' x 64 ) },
    },
);

for my $c (@CASES) {
    subtest "$c->{reason}: $c->{what}" => sub {
        my $docroot = site();
        my $out     = $c->{run}->($docroot);
        like( $out, qr/"ok":0/, 'the submission was refused' ) or diag($out);

        my @rows = events($docroot);
        my @blocked = grep { ( $_->{outcome} // '' ) eq 'blocked' } @rows;
        is( scalar @blocked, 1, 'exactly one blocked event was recorded' )
            or diag( "A refusal with no reason code records NOTHING, so the "
                . "sysop's \"controls stopped N\" undercounts in silence.\n"
                . '  rows: ' . scalar(@rows) );
        is( $blocked[0] ? $blocked[0]{reason} : '(none)',
            $c->{reason}, "recorded under '$c->{reason}'" )
            or diag( 'The code must come from the control that fired, not from '
                . 'the words it printed.' );
        is( $blocked[0] ? $blocked[0]{form} : '(none)',
            'contact', 'and attributed to the form' );
    };
}

subtest 'rate: the limit blocks and is counted under its own reason' => sub {
    # The one control that needs state, so it needs two POSTs: a limit of one
    # lets the first through and refuses the second.
    my $docroot = site( rate_limit => 1 );
    my $first   = submit($docroot);
    like( $first, qr/"ok":1/, 'the first submission is accepted' ) or diag($first);

    my $second = submit($docroot);
    like( $second, qr/"ok":0/, 'the second is refused' ) or diag($second);

    my @rows = events($docroot);
    my @blocked = grep { ( $_->{outcome} // '' ) eq 'blocked' } @rows;
    my @stored  = grep { ( $_->{outcome} // '' ) eq 'stored' } @rows;
    is( scalar @stored,  1, 'the accepted one is counted as stored' );
    is( scalar @blocked, 1, 'and the refused one as blocked' );
    is( $blocked[0] ? $blocked[0]{reason} : '(none)', 'rate', "under 'rate'" );
};

# --- and what must NOT be counted -------------------------------------------

subtest 'a refusal that is not an anti-spam control is not counted' => sub {
    # SM216-2's contract, and it is the half that makes the counts mean
    # something: method, validation and delivery failures are not controls
    # stopping spam, and folding them in would inflate the figure with the
    # site's own faults. A refusal with no reason code is the mechanism, so
    # this also proves the default is silence rather than `other`.
    #
    # AN UNKNOWN FORM NAME, NOT A BAD METHOD, and the difference is the whole
    # value of this subtest. It was written first with `method => 'GET'`, and a
    # sabotage - making that refusal declare a code - did not fail it: the
    # method check fires before $name is parsed, and _record_form_event returns
    # early with no form to attribute the event to. So the subtest was passing
    # on the missing name and would have passed with the contract broken.
    #
    # `Form 'nosuch' not configured` is raised AFTER the name is known, by
    # load_form_conf, which is a configuration fault rather than a control. It
    # is therefore the case where "no code means no count" is the only thing
    # keeping the event out of the report.
    my $docroot = site();
    my $out     = submit( $docroot, form => 'nosuch' );
    unlike( $out, qr/"ok":1/, 'the submission was refused' ) or diag($out);

    my @blocked = grep { ( $_->{outcome} // '' ) eq 'blocked' } events($docroot);
    is( scalar @blocked, 0, 'and nothing was counted as a blocked submission' )
        or diag( 'A misconfigured form counted as a spam block would tell the '
            . "sysop their controls stopped something. Nothing did.\n"
            . '  reason recorded: '
            . ( $blocked[0] ? $blocked[0]{reason} : '' ) );
};

# --- the roll-call ----------------------------------------------------------
#
# The cases above each prove one code works. This proves the SET is complete
# against the source, which is the half that catches a sixth control added
# without a code - the failure the mechanism cannot prevent on its own.
subtest 'every anti-spam control in the source declares a reason code' => sub {
    my $src = do {
        open my $fh, '<', $handler or die $!;
        local $/;
        <$fh>;
    };

    # The codes this file drove, and the codes the source hands to a refusal.
    my %driven = map { $_->{reason} => 1 } @CASES;
    $driven{rate} = 1;

    my %declared;
    while ( $src =~ /reject(?:_user)?\(\s*(?:'[^']*'|"[^"]*")(?:\s*\.\s*(?:'[^']*'|"[^"]*"))*\s*,\s*'([a-z_]+)'\s*\)/g ) {
        $declared{$1}++;
    }
    cmp_ok( scalar keys %declared, '>=', 5,
        'the source was parsed (five or more codes found)' )
        or diag( 'If this drops, the call shape changed and the roll-call below '
            . 'passes by comparing two empty sets.' );

    for my $code ( sort keys %declared ) {
        ok( $driven{$code}, "'$code' is a code this file actually drives" )
            or diag( "plugins/form-handler.pl raises a refusal under '$code' "
                . 'and nothing here proves it is recorded. Add a case above: '
                . 'an uncounted control is invisible to the sysop, which is '
                . 'the whole of SM888 A7.' );
    }
    for my $code ( sort keys %driven ) {
        ok( $declared{$code}, "'$code' is still raised by the source" )
            or diag( 'This file drives a code the handler no longer produces, '
                . 'so its case above is testing nothing.' );
    }
};

done_testing();
