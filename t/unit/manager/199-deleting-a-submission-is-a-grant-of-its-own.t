#!/usr/bin/perl
# SM924: a partner account could READ every submission on a site and delete none
# of them.
#
# Submission delete was interactive-only (SM214: a destructive act on personal
# data, often on the only copy, so a human confirms it). The consequence the field
# found: an agent that fills a form to test it leaves a row only a person can
# clear, and the reporter's own test data was the litter.
#
# THE FILING'S OWN RECOMMENDATION WAS MEASURED FALSE FIRST. It said the row
# "already records enough to know" who created a submission. It does not: a stored
# submission carries no actor at all, deliberately - form-handler.pl records a
# public submission as having none because a forged `_auth_user` had been reaching
# the ACTOR COLUMN of the audit trail - and `_ip` is the front proxy's address,
# identical on every row of every site behind it (SM929). So "delete rows the caller
# created" has nothing to key on.
#
# RULED, re-asked on that measurement: A CAPABILITY OF ITS OWN, OFF BY DEFAULT, and
# NAMED FOR WHAT IT PERMITS - deleting ANY submission on the site. An operator who
# grants it on the softer reading has granted the harder thing, so the words matter
# as much as the gate.
use strict;
use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/../../lib";
use lib "$FindBin::Bin/../../../lib";
use TestHelper qw(repo_root gate_caps);
use Lazysite::Capabilities   ();
use Lazysite::Auth::Settings ();

my $root = repo_root();
my $api  = do {
    open my $fh, '<', "$root/lazysite-manager-api.pl" or die $!;
    local $/;
    <$fh>;
};

my %need_caps = gate_caps($api);
ok( scalar keys %need_caps, 'the token gate table was found' )
    or BAIL_OUT('no gate table - nothing below compares anything');

subtest 'the two deletes are reachable with the grant, and only with it' => sub {
    for my $act (qw(form-submission-delete form-submissions-delete-bulk)) {
        my $caps = $need_caps{$act};
        ok( $caps, "the token gate names $act - it was absent, which IS cookie-only" )
            or next;
        ok( $caps->{delete_submissions}, "$act needs delete_submissions" );
        ok( !$caps->{read_submissions},
            "$act does not ALSO accept read_submissions - reading and deleting are "
                . 'different authorities, and a grant that read everything was '
                . 'exactly what could delete nothing' );
        ok( !$caps->{manage_forms},
            "$act does not accept manage_forms either - that capability is "
                . 'definition-only (SM652)' );
    }
};

subtest 'it is off by default' => sub {
    # The vocabulary knows it, so it can be granted; nothing seeds it, so an
    # upgrade grants it to nobody and the interactive path is unchanged.
    ok( ( grep { $_ eq 'delete_submissions' } @Lazysite::Auth::Settings::CAP_KEYS ),
        'the store knows the capability, so an operator can grant it' );

    my $install = do {
        open my $fh, '<', "$root/install.pl" or die $!;
        local $/;
        <$fh>;
    };
    unlike( $install, qr/delete_submissions/,
        'and the installer seeds it to NO group - a site that upgrades gains an '
            . 'ability for nobody, which is what "off by default" has to mean' );
};

subtest 'the capability says what it permits, not what one would like it to' => sub {
    # describe()'s `capabilities` is keyed by name, not a list - the first draft of
    # this read ->{actions} as an array and found nothing, which would have passed
    # as "no entry" if the assertion had been written the other way round.
    my $info = Lazysite::Capabilities::describe();
    my $entry = $info->{capabilities}{delete_submissions};
    ok( $entry, 'the capability is published' ) or return;

    # PER FIELD, not over both joined. A sabotage pass softened the TITLE to
    # "delete your own form submissions" and this subtest still passed, because the
    # grants line elsewhere still said "anybody's" - two fields covering one claim,
    # so neither was actually pinned. An operator reads the title in the grid.
    my $title  = $entry->{title}  // '';
    my $grants = $entry->{grants} // '';

    like( $title, qr/\bANY\b/,
        'the TITLE says ANY submission - the filing wanted "delete your own test '
            . 'data", and that is not what this grant is' );
    # The title does contain the words "your own" - inside the sentence that
    # REFUSES that reading. An absence check failed against correct text, which is
    # the right way round for this one: the softer reading has to be named to be
    # ruled out, and the filing asked for exactly that reading.
    like( $title, qr/Not "delete your own"/,
        'and names the softer reading in order to refuse it - "delete your own" is '
            . 'what the filing wanted and what this grant is not' );
    like( $title, qr/records no author/,
        'the title says why it cannot be narrowed' );
    like( $grants, qr/\banybody\b/,
        'and the grants line says whose submissions it reaches' );
    like( $grants, qr/nothing on the row says who submitted it/,
        'with the reason in its own words there too - the row records no author' );
    like( $title, qr/[Oo]ff by default/, 'and that it is off by default' );
};

subtest 'the reads are untouched' => sub {
    # The point of the ruling is a second grant, not a wider first one. If
    # read_submissions had gained the deletes, every existing agent that reads
    # leads would have been able to destroy them on upgrade.
    my $r = $need_caps{'form-submissions'};
    ok( $r && $r->{read_submissions}, 'form-submissions still needs read_submissions' );
    ok( !$r->{delete_submissions},
        'and does not require the new one - reading did not get harder' );

    my $info = Lazysite::Capabilities::describe();
    my $read = $info->{capabilities}{read_submissions};
    ok( $read, 'read_submissions is still published' ) or return;
    my @api = @{ $read->{unlocks}{api} // [] };
    ok( !( grep { /delete/ } @api ),
        'and unlocks no delete - the grant that reads personal data must not also '
            . 'advertise removing it' );
};

done_testing();
