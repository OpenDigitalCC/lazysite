#!/usr/bin/perl
# SM1111 (0.15.7 test plan, "Found while getting mail to send", U9): "The sendmail
# method's failure is opaque. 'sendmail failed: exit 256' is the raw wait status
# (exit code 1), with no stderr."
#
# The failure decodes the wait status (an exit code, or the signal) and carries
# the first lines of what sendmail wrote to stderr; a success is unchanged.
use strict;
use warnings;
use Test::More;
use JSON::PP   ();
use File::Path qw(make_path);
use FindBin;
use lib "$FindBin::Bin/../../lib", "$FindBin::Bin/../../../lib";
use TestHelper qw(repo_root site_tempdir run_child);

my $script = repo_root() . '/plugins/form-smtp.pl';
my $d      = site_tempdir();
make_path("$d/lazysite/forms");
sub spit { my ( $p, $t ) = @_; open my $fh, '>', $p or die "$p: $!"; print {$fh} $t; close $fh; return }

sub mock {
    my ($body) = @_;
    my $m = "$d/sendmail";
    spit( $m, "#!$^X\nlocal \$/; my \$in = <STDIN>;\n$body\n" );
    chmod 0755, $m;
    spit( "$d/lazysite/forms/smtp.conf", "method: sendmail\nsendmail_path: $m\nfrom: a\@example.org\n" );
}

sub send_it {
    local $ENV{DOCUMENT_ROOT} = $d;
    my $res = run_child( [ $^X, $script, '--pipe' ],
        stdin => JSON::PP::encode_json( { config => { to => 'ada@example.net' }, form => { message => 'hi' } } ) )->{out};
    return JSON::PP::decode_json( $res || '{}' );
}

mock('exit 0;');
ok( send_it()->{ok}, 'canary: a sendmail that succeeds is a send that succeeds' );

mock(q{print STDERR "sendmail: fatal: no MTA is configured\nsecond line\nthird\nfourth line\n"; exit 1;});
my $r = send_it();
ok( !$r->{ok}, 'a sendmail that exits 1 fails the send' );
like( $r->{error}, qr/\Asendmail failed: exit code 1/, 'and says the exit CODE, not the raw wait status' ) or diag( $r->{error} );
unlike( $r->{error}, qr/\b256\b/, '...and not 256' );
like( $r->{error}, qr/sendmail: fatal: no MTA is configured/, '...and carries what sendmail said' );
like( $r->{error}, qr/second line/, '...including its next lines' );
unlike( $r->{error}, qr/fourth line/, '...but only the first few' );
unlike( $r->{error}, qr/\n./, '...as one line' );

mock(q{print STDERR "dying\n"; kill 'KILL', $$; sleep 5;});
$r = send_it();
ok( !$r->{ok}, 'a sendmail killed by a signal fails the send' );
like( $r->{error}, qr/\Asendmail failed: killed by signal 9 \(KILL\)/, '...and names the signal' ) or diag( $r->{error} );

mock('exit 75;');
$r = send_it();
like( $r->{error}, qr/\Asendmail failed: exit code 75\z/, 'a sendmail that says nothing is reported without an empty tail' ) or diag( $r->{error} );

done_testing;
