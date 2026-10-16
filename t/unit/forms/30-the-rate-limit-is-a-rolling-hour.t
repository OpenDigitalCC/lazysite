#!/usr/bin/perl
# SM935: the form rate limit bucketed on a CALENDAR hour, so a limit of five
# permitted ten.
#
# MEASURED IN THE SOURCE, not supposed from a report: the key was "$ip:$hour"
# with $hour = int(time/3600), so the window reset on the clock rather than on
# the submitter. Five submissions at 10:59:59 and five at 11:00:00 is ten in one
# second, inside the rules - and reachable by anyone who notices the clock.
#
# THE VALUE IS NOW THE SUBMISSION TIMES and the window is the hour before now,
# so the limit the operator set is the limit that applies. The key is the address
# alone, which also removes an ambiguity the old scheme carried: "$ip:$hour" put
# a colon-separated number after an IPv6 address that already contains colons,
# and the purge had to parse it back out.
#
# SM952 (ruled R8): the key is now FORM AND ADDRESS, and the check only reads -
# a time is recorded only when the submission is stored (record_rate_stamp), so
# a post refused by validation spends nothing.
#
# WHY THIS FILE CALLS THE SUB DIRECTLY. The boundary is a property of the clock,
# and driving it through a real POST would need the test to wait an hour or to
# fake time for the whole CGI. The sub takes the address and the ceiling and
# keeps its state in a DB_File under $FORMS_DIR, so it can be exercised honestly
# in isolation - and the `reject` it calls is overridden here so a refusal is an
# event this file can count rather than an exit.
use strict;
use warnings;
use Test::More;
use File::Path qw(make_path);
use Fcntl qw(O_RDWR O_CREAT);    # this file ties the DB directly, so it needs them too
use DB_File;
use FindBin;
use lib "$FindBin::Bin/../../lib";
use TestHelper qw(repo_root site_tempdir);

my $root = repo_root();
my $doc  = site_tempdir();
make_path("$doc/lazysite/forms");

# The handler is a CGI: loading it would run it. The rate limiter is lifted the
# way t/unit/processor/86 lifts the YAML subs - one definition, no module to use.
my $src = do {
    open my $fh, '<', "$root/plugins/form-handler.pl" or die $!;
    local $/;
    <$fh>;
};
my $sub = join "\n", map {
    my ($one) = $src =~ /^(sub \Q$_\E \{.*?^\})/ms
        or BAIL_OUT("could not lift $_ out of plugins/form-handler.pl");
    $one;
} qw(check_rate_limit record_rate_stamp _rate_key _rate_stamps _rate_db _audit_rate_refusal);

my @REJECTED;
my $code = <<'HEAD' . $sub . "\n1;\n";
package RL;
use strict;
use warnings;
use Fcntl qw(O_RDWR O_CREAT);
use DB_File;
our $FORMS_DIR;
our $DB_HASH = $DB_File::DB_HASH;
sub _ensure_dir_for { return 1 }
sub reject { push @main::REJECTED, $_[1] // 'rate'; die "REJECTED\n" }
sub reject_user { push @main::REJECTED, $_[1] // 'rate'; die "REJECTED\n" }
our $LAZYSITE_DIR;    # undef: the audit helper writes nothing here (SM1115)
HEAD
eval $code or BAIL_OUT("lifted rate limiter did not compile: $@");
$RL::FORMS_DIR = "$doc/lazysite/forms";

# Returns 1 if the submission was accepted, 0 if the limiter refused it. An
# accepted one is stored, so it is recorded; $invalid stands for a post the
# form then refused, which is checked but never recorded.
sub submit {
    my ( $ip, $form, $invalid ) = @_;
    $form //= 'contact';
    @REJECTED = ();
    my $ok = eval { RL::check_rate_limit( $form, $ip, 5 ); 1 };
    return 0 unless $ok && !@REJECTED;
    RL::record_rate_stamp( $form, $ip, 5 ) unless $invalid;
    return 1;
}

# Rewrite the stored times so a submission looks as though it happened N seconds
# ago. This is the only way to reach across the window without waiting.
sub age_stamps_by {
    my ( $ip, $secs ) = @_;
    my $key = "contact $ip";
    my %db;
    tie( %db, 'DB_File', "$RL::FORMS_DIR/.rate-limit.db",
        O_RDWR | O_CREAT, 0o600, $DB_File::DB_HASH )
        or die 'tie failed';
    my @s = map { $_ - $secs } grep { /\A\d+\z/ } split /,/, ( $db{$key} // '' );
    $db{$key} = join ',', @s;
    untie %db;
    return scalar @s;
}

subtest 'the ceiling is the ceiling' => sub {
    is( submit('10.0.0.1'), 1, "submission $_ accepted" ) for 1 .. 1;
    is( submit('10.0.0.1'), 1, 'second accepted' );
    is( submit('10.0.0.1'), 1, 'third accepted' );
    is( submit('10.0.0.1'), 1, 'fourth accepted' );
    is( submit('10.0.0.1'), 1, 'fifth accepted - the limit is five' );
    is( submit('10.0.0.1'), 0, 'the SIXTH is refused' );
};

subtest 'THE REPORTED CASE: a clock boundary grants nothing' => sub {
    # Under the old scheme these five sat in the previous calendar hour's bucket
    # and the next five went into a fresh one - ten inside a second. Ageing them
    # by 61 seconds moves them across any minute or hour boundary you like; what
    # decides the outcome now is that they are still inside the rolling hour.
    is( age_stamps_by( '10.0.0.1', 61 ), 5, 'the five submissions are now 61s old' );
    is( submit('10.0.0.1'), 0,
        'still refused - crossing a boundary is not a new allowance' )
        or diag( 'This is the defect: a limit of five that permits ten whenever '
            . 'the clock happens to tick over.' );
};

subtest 'and the window really does roll' => sub {
    # Just inside: 3500s ago is still within the hour, so no allowance returns.
    is( age_stamps_by( '10.0.0.2', 0 ), 0, 'a fresh address has no history' );
    submit('10.0.0.2') for 1 .. 5;
    is( submit('10.0.0.2'), 0, 'five then refused' );
    age_stamps_by( '10.0.0.2', 3500 );
    is( submit('10.0.0.2'), 0, 'at 3500s the window has not passed' );

    # Just outside: past 3600s the earliest submissions leave the window.
    age_stamps_by( '10.0.0.2', 200 );    # now 3700s old
    is( submit('10.0.0.2'), 1,
        'past the hour the allowance returns - a rolling window, not a frozen one' );
};

subtest 'one address does not spend another address allowance' => sub {
    submit('10.0.0.3') for 1 .. 5;
    is( submit('10.0.0.3'), 0, 'the third address hits its own ceiling' );
    is( submit('10.0.0.4'), 1, 'and a fourth address is unaffected' );
};

subtest 'the stored row stays bounded' => sub {
    # A decision only needs to know whether there are $limit stamps in the
    # window, so an address submitting under the limit for a year must not grow
    # one row without bound.
    my %db;
    tie( %db, 'DB_File', "$RL::FORMS_DIR/.rate-limit.db",
        O_RDWR | O_CREAT, 0o600, $DB_File::DB_HASH )
        or BAIL_OUT('tie failed');
    my @s = split /,/, ( $db{'contact 10.0.0.1'} // '' );
    untie %db;
    cmp_ok( scalar @s, '<=', 5, 'at most `limit` times are kept per address' );
};

subtest 'a row left by the OLD scheme is cleared, not trusted' => sub {
    # The old value was a bare count under an "ip:hour" key. A count is not a
    # timestamp inside the window, so the purge empties it - and the visible
    # consequence of the upgrade is that counters start from zero, which is the
    # safe direction.
    my %db;
    tie( %db, 'DB_File', "$RL::FORMS_DIR/.rate-limit.db",
        O_RDWR | O_CREAT, 0o600, $DB_File::DB_HASH )
        or BAIL_OUT('tie failed');
    my $old_hour = int( time() / 3600 ) - 1;
    $db{"10.9.9.9:$old_hour"} = 99;
    delete $db{_purged_hour};    # make the next call run the purge
    untie %db;

    is( submit('10.9.9.9'), 1,
        'a legacy row does not refuse a first submission' );

    tie( %db, 'DB_File', "$RL::FORMS_DIR/.rate-limit.db",
        O_RDWR | O_CREAT, 0o600, $DB_File::DB_HASH )
        or BAIL_OUT('tie failed');
    ok( !exists $db{"10.9.9.9:$old_hour"}, 'and the legacy key is gone' );
    untie %db;
};

subtest 'SM952: one form does not spend another form allowance' => sub {
    # The 0.15.2 edge walk, R8: five posts to `contact` refused a new form's
    # first post from the same address.
    submit( '10.0.0.5', 'contact' ) for 1 .. 5;
    is( submit( '10.0.0.5', 'contact' ), 0, 'the address has spent contact' );
    is( submit( '10.0.0.5', 'signup' ), 1, 'and another form still takes its first post' )
        or diag('The limit is per form and address (R8). Keyed on the address alone it is not.');
};

subtest 'SM952: a post the form refuses spends nothing' => sub {
    submit( '10.0.0.6', 'contact', 'invalid' ) for 1 .. 5;
    is( submit( '10.0.0.6', 'contact' ), 1,
        'five refused-as-invalid posts, and the next good one is still accepted' )
        or diag('Only a stored submission counts (R8). A visitor correcting a mistake is never locked out.');
    submit( '10.0.0.6', 'contact' ) for 1 .. 4;
    is( submit( '10.0.0.6', 'contact' ), 0, 'and five stored ones still reach the ceiling' );
};

done_testing();
