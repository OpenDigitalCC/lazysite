#!/usr/bin/perl
# SM917: the processor's own `_cannot_read` says the same thing Util's does.
#
# ADR 0001 keeps the render path module-free, so the processor cannot call
# Lazysite::Util::cannot_read and carries its own copy instead. That is the
# established trade here (t/lint/127 and t/lint/131 pin other copies the same
# way), and the cost of it is drift: two subs with one name and one job, edited
# a release apart.
#
# What must stay true of BOTH, because each clause is a decision and not a
# detail:
#
#   1. ENOENT returns BEFORE anything is logged. Absent is a real answer - a file
#      a site has never had is not a fault, and warning about it trains an
#      operator to ignore the warning. This is the clause most likely to be
#      "tidied" away by someone who reads the sub as error handling.
#   2. It returns undef, so it can BE the failure branch of an open rather than
#      sit beside one.
#   3. It logs the path, the errno and the unix user. SM766's version threw the
#      errno away and SM768 logged it blank, so these three fields are the whole
#      point of the sub, and the errno is read before getpwuid because getpwuid
#      is free to reset $!.
use strict;
use warnings;
use Test::More;
use FindBin;

my $root = "$FindBin::Bin/../..";

sub body_of {
    my ( $file, $name ) = @_;
    open my $fh, '<', "$root/$file" or die "$file: $!";
    my @lines = <$fh>;
    close $fh;
    my ( $in, $depth, @body ) = ( 0, 0 );
    for my $l (@lines) {
        if ( !$in && $l =~ /^\s*sub \Q$name\E\b/ ) { $in = 1 }
        next unless $in;
        push @body, $l;
        $depth++ while $l =~ /\{/g;
        $depth-- while $l =~ /\}/g;
        last if @body > 1 && $depth <= 0;
    }
    return join '', @body;
}

my %impl = (
    'lazysite-processor.pl (its own copy)' => body_of( 'lazysite-processor.pl', '_cannot_read' ),
    'lib/Lazysite/Util.pm (the original)'  => body_of( 'lib/Lazysite/Util.pm',  'cannot_read' ),
);

for my $which ( sort keys %impl ) {
    my $b = $impl{$which};

    # ORDERING IS CHECKED ON CODE, NOT PROSE. The first version of this lint
    # asserted "the errno is captured before getpwuid" against the raw body and
    # failed on Util - because the SM768 comment immediately above that line says
    # "read $! BEFORE getpwuid", so the word appeared earlier than the code it
    # describes. A lint that reads its own subject's explanation as the subject
    # is the mistake this file exists to catch elsewhere.
    ( my $code = $b ) =~ s/^\s*#.*$//mg;

    subtest $which => sub {
        ok( length $b, 'the sub was found' ) or return;

        # 1. absent is silent, and it returns FIRST.
        like( $b, qr/return \s+ undef \s+ if \s+ \$!\{ENOENT\}/x,
            'ENOENT returns undef' );

        my ($enoent_at) = $code =~ /(.*?)\$!\{ENOENT\}/s;
        unlike( $enoent_at, qr/log_event/,
            'and it returns BEFORE anything is logged - absent is not a fault' );

        # 2. undef, so the sub can be the whole failure branch.
        my @returns = $b =~ /return\s+([^;]*);/g;
        ok( ( grep { /undef/ } @returns ) >= 2,
            'every return is undef, so it can stand as an open\'s failure branch' )
            or diag( "returns found: " . join( ' | ', @returns ) );

        # 3. the three fields, and the errno read before getpwuid can reset it.
        like( $b, qr/\bfile\s*=>/,      'logs the path' );
        like( $b, qr/\berror\s*=>/,     'logs the errno' );
        like( $b, qr/\bunix_user\s*=>/, 'logs the unix user' );

        my ($err_pos) = $code =~ /(.*?)my \s+ \$err \s* = \s* "\$!"/xs;
        ok( defined $err_pos && $err_pos !~ /getpwuid/,
            'the errno is captured BEFORE getpwuid, which may reset $!' );

        like( $b, qr/WARN/, 'logged at WARN - a fault, not a note' );
    };
}

# A HELPER NOTHING CALLS IS NOT A FIX. The assertions above hold the sub honest;
# this holds its caller honest, and it exists because a sabotage run found the
# gap: deleting the CALL in _visitor_key left every test above passing, because
# none of them look at callers.
#
# _visitor_key falls back to a minted salt when the secret is empty, which is
# correct for a site that has no secret and was ALSO what happened when the
# secret existed and could not be read - so an unreadable secret silently
# re-keyed every visitor token. The symptom is returning visitors counting as new
# ones, which looks like traffic rather than a fault.
subtest 'the auth-secret read reports when it cannot read' => sub {
    my $body = body_of( 'lazysite-processor.pl', '_visitor_key' );
    ok( length $body, '_visitor_key was found' ) or return;

    like( $body, qr/auth\/\.secret/, 'it reads the auth secret' );
    like(
        $body,
        qr/else \s* \{ [^}]* _cannot_read \s* \(/xs,
        'and a failed open reports through _cannot_read rather than falling '
            . 'silently through to the salt'
    );
};

# The two must not drift into different WORDING either: a sysop grepping the logs
# of a site that runs both should find one sentence, not two.
subtest 'both copies log the same sentence' => sub {
    my @msg;
    for my $which ( sort keys %impl ) {
        my ($m) = $impl{$which} =~ /"(cannot read [^"]+)"/;
        push @msg, $m // '(none)';
    }
    is( $msg[0], $msg[1], 'the message is identical in both' )
        or diag( "processor: $msg[0]\nutil:      $msg[1]" );
};

done_testing();
