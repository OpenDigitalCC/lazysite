#!/usr/bin/perl
# SM1115: a rate-limited visitor is told so, and the operator can see it.
#
# The 0.15.8 edge walk: past the per-form, per-address limit the visitor saw
# "An error occurred - please try again." and nothing reached the audit trail.
# check_rate_limit refused with `reject`, whose message is never shown, and no
# refusal of a submission was audited.
#
# What this holds, on the limiter lifted out of plugins/form-handler.pl (as
# t/unit/forms/30 does) with the real audit trail:
#
# - the refusal is a USER message: it names the limit and when to try again
# - its reason code is still `rate`, so the form's blocked count is unchanged
# - the first refusal in an hour writes one `submit <form> fail` row naming the
#   rate limit; further refusals in that hour write none
use strict;
use warnings;
use Test::More;
use File::Path qw(make_path);
use Fcntl qw(O_RDWR O_CREAT);
use DB_File;
use FindBin;
use lib "$FindBin::Bin/../../lib";
use lib "$FindBin::Bin/../../../lib";
use TestHelper qw(repo_root site_tempdir);

my $root = repo_root();
my $doc  = site_tempdir();
make_path( "$doc/lazysite/forms", "$doc/lazysite/logs" );

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

our ( @SAID, @REASON );
my $code = <<'HEAD' . $sub . "\n1;\n";
package RL;
use strict;
use warnings;
use Fcntl qw(O_RDWR O_CREAT);
use DB_File;
our ( $FORMS_DIR, $LAZYSITE_DIR );
our $DB_HASH = $DB_File::DB_HASH;
sub _ensure_dir_for { return 1 }
sub reject      { push @main::SAID, "PLAIN:$_[0]"; push @main::REASON, $_[1]; die "REJECTED\n" }
sub reject_user { push @main::SAID, "USER:$_[0]";  push @main::REASON, $_[1]; die "REJECTED\n" }
HEAD
eval $code or BAIL_OUT("lifted rate limiter did not compile: $@");
$RL::FORMS_DIR    = "$doc/lazysite/forms";
$RL::LAZYSITE_DIR = "$doc/lazysite";

sub post {
    my ($ip) = @_;
    my $ok = eval { RL::check_rate_limit( 'contact', $ip, 2 ); 1 };
    RL::record_rate_stamp( 'contact', $ip, 2 ) if $ok;
    return $ok ? 1 : 0;
}
sub trail {
    open my $fh, '<', "$doc/lazysite/logs/audit.log" or return ();
    return grep { / \| submit \| / } <$fh>;
}

is( post('192.0.2.7') + post('192.0.2.7'), 2, 'two submissions inside the limit of two' );
ok( !post('192.0.2.7'), 'the third is refused' );

subtest 'the visitor is told why and when' => sub {
    like( $SAID[-1], qr/\AUSER:/, 'a USER message, shown to the submitter' );
    like( $SAID[-1], qr/Too many submissions of this form from your address in the last hour/,
        'naming the limit' );
    like( $SAID[-1], qr/try again in about (?:60|59) minutes\./, 'and when the next is accepted' );
    is( $REASON[-1], 'rate', 'its reason code is still rate, for the blocked count' );
};

ok( !post('192.0.2.7'), 'a fourth is refused too' );

subtest 'the operator sees it once an hour' => sub {
    my @rows = trail();
    is( scalar @rows, 1, 'one audit row for two refusals' ) or diag explain \@rows;
    like( $rows[0] // '', qr/ \| submit \| contact \| 192\.0\.2\.7 \| fail \| form \| rate limit: 2 an hour/,
        'submit contact fail, naming the rate limit' );
};

ok( post('198.51.100.9'), 'another address is not limited' );

done_testing;
