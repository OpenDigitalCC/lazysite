#!/usr/bin/perl
# SM1161 (L5): `lazysite check` warns when a scheduled binding's Odoo key
# expires within 14 days, or has expired. The date is the one odoo-status last
# read from OOM (lazysite/odoo/scheduled-expiry.json), so the check needs no
# network; a key whose expiry was never read, or that OOM does not report,
# is said so and is not a warning.
use strict;
use warnings;
use Test::More;
use File::Path qw(make_path);
use JSON::PP qw(encode_json);
use FindBin;
use lib "$FindBin::Bin/../lib";
use TestHelper qw(repo_root site_tempdir);

my $script = repo_root() . '/tools/lazysite-check.pl';
plan skip_all => 'lazysite-check.pl missing' unless -f $script;

sub site {
    my ( $sched, $expiry ) = @_;
    my $doc = site_tempdir();
    make_path("$doc/lazysite/$_") for qw(auth cache logs manager odoo);
    open my $cf, '>', "$doc/lazysite/lazysite.conf" or die $!;
    print {$cf} "site_name: T\n";
    close $cf;
    for ( [ 'scheduled', $sched ], [ 'scheduled-expiry', $expiry ] ) {
        next unless $_->[1];
        open my $fh, '>', "$doc/lazysite/odoo/$_->[0].json" or die $!;
        print {$fh} encode_json( $_->[1] );
        close $fh;
    }
    return $doc;
}
sub run_check { my ($doc) = @_; return qx($^X \Q$script\E --docroot \Q$doc\E 2>&1) }
sub line { my ( $out, $re ) = @_; my ($l) = grep { /$re/ } split /\n/, $out; return $l // '' }

my $day = 86400;
my %S = map { $_ => { id => "sched-$_", login => "bot-$_" } } qw(soon gone fine later none);
my %E = (
    soon  => { login => 'bot-soon',  key => 'sched-soon',  expires_by => time + 5 * $day,   expires => 'x', expiry => 'exact', read_at => time },
    gone  => { login => 'bot-gone',  key => 'sched-gone',  expires_by => time - 2 * $day,   expires => 'x', expiry => 'exact', read_at => time },
    fine  => { login => 'bot-fine',  key => 'sched-fine',  expires_by => time + 60 * $day,  expires => 'x', expiry => 'exact', read_at => time },
    later => { login => 'bot-later', key => 'sched-later', expiry => 'not-reported', read_at => time },
);
my $out = run_check( site( \%S, \%E ) );

like( line( $out, qr/bot-soon/ ), qr/WARN|warn/i, 'a key expiring in 5 days is a warning' );
like( line( $out, qr/bot-soon/ ), qr/expires/, 'that says it expires' );
like( line( $out, qr/bot-gone/ ), qr/WARN|warn/i, 'an expired key is a warning' );
like( line( $out, qr/bot-gone/ ), qr/expired/, 'that says it has expired' );
like( line( $out, qr/bot-fine/ ), qr/^\[\s*ok\s*\]/i, 'a key with 60 days left is ok' );
like( line( $out, qr/bot-later/ ), qr/^\[\s*ok\s*\].*not reported/i, 'a key OOM reports no expiry for is said so, not warned' );
like( line( $out, qr/bot-none/ ), qr/^\[\s*ok\s*\].*not (?:yet )?read/i, 'a key whose expiry was never read is said so' );
unlike( $out, qr/sched-soon|sched-gone/, 'no key file name is shown' );

my $quiet = run_check( site() );
unlike( $quiet, qr/scheduled .*Odoo|Odoo .*scheduled/i, 'a site with no scheduled keys has no line' );

done_testing();
