#!/usr/bin/perl
# The login page shows "Forgot password?" only when SMTP is configured (the
# emailed-reset path is gated on lazysite/forms/smtp.conf existing), so the link
# is hidden when there is no way to send the reset email.
use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use File::Copy qw(copy);
use FindBin;
use lib "$FindBin::Bin/../lib";
use TestHelper qw(repo_root run_processor);

my $root    = repo_root();
my $docroot = tempdir( CLEANUP => 1 );
make_path("$docroot/lazysite/forms");

open my $c, '>', "$docroot/lazysite/lazysite.conf" or die $!;
print $c "site_name: Test\n";
close $c;
copy( "$root/starter/login.md", "$docroot/login.md" ) or die $!;
open my $nf, '>', "$docroot/404.md" or die $!;
print $nf "---\ntitle: NF\n---\nNF.\n";
close $nf;

my $no = run_processor( $docroot, '/login' );
unlike( $no, qr/Forgot password/, 'no SMTP: reset link hidden' );

open my $s, '>', "$docroot/lazysite/forms/smtp.conf" or die $!;
print $s "host: mail.example\n";
close $s;
my $yes = run_processor( $docroot, '/login' );
like( $yes, qr/Forgot password/, 'SMTP configured: reset link shown' );
like( $yes, qr{href="/forgot"}, 'reset link points at /forgot' );

done_testing;
