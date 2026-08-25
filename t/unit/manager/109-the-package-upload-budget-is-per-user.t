#!/usr/bin/perl
# SM548: action_site_backup_upload called check_upload_rate($DOCROOT) where
# the signature is ($username, $content_length). The budget was therefore
# keyed on the docroot - shared by every user of the instance - and the byte
# limit compared against undef, so it never fired. Found by the backups
# structural review (N6), proven by probe tmp/bp-probe-rate-key.t.
#
# The API's $auth_user is file-lexical and the load-only path returns before
# authentication, so the per-user half is pinned at the source (the call
# passes $auth_user, as the file-upload call does) and the byte half is
# driven for real: a package over the hourly byte budget is refused.
use strict;
use warnings;
use Test::More;
use FindBin;
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use lib "$FindBin::Bin/../../lib";
use TestHelper qw(repo_root);

eval { require DB_File };
plan skip_all => 'DB_File not available' if $@;

my $docroot = tempdir( CLEANUP => 1 );
make_path("$docroot/lazysite/manager");
open my $cf, '>', "$docroot/lazysite/lazysite.conf" or die $!;
print {$cf} "manager_upload_rate_count: 5\nmanager_upload_rate_mb: 1\n";
close $cf;

BEGIN {
    $ENV{LAZYSITE_API_LOAD_ONLY} = 1;
}
$ENV{DOCUMENT_ROOT} = $docroot;
my $root = repo_root();
{
    package main;
    do "$root/lazysite-manager-api.pl" or die "load failed: $@";
}

sub multipart {
    my ( $boundary, $filename, $data ) = @_;
    return "--$boundary\r\n"
        . qq{Content-Disposition: form-data; name="file"; filename="$filename"\r\n}
        . "Content-Type: application/gzip\r\n\r\n"
        . $data
        . "\r\n--$boundary--\r\n";
}

subtest 'the byte budget applies to a package upload' => sub {
    my $b = 'BoUnDaRy1234';
    local $ENV{CONTENT_TYPE} = "multipart/form-data; boundary=$b";
    my $body = multipart( $b, 'site.tar.gz', 'x' x ( 1024 * 1024 + 512 ) );
    my @warn;
    local $SIG{__WARN__} = sub { push @warn, $_[0] };
    my $r = main::action_site_backup_upload($body);
    is( $r->{ok}, 0, 'a package over the hourly byte budget is refused' ) or diag explain $r;
    is( $r->{kind}, 'rate', 'as a rate refusal' );
    ok( !( grep { /uninitialized value \$content_length/ } @warn ),
        'and the length was not undefined' )
        or diag @warn;
    my @left = glob "$docroot/lazysite/backups/lazysite-site-*";
    is( scalar @left, 0, 'nothing was stored' );
};

subtest 'the budget is keyed on the user, as the file upload is' => sub {
    open my $fh, '<', "$root/lazysite-manager-api.pl" or die $!;
    my $src = do { local $/; <$fh> };
    close $fh;
    my ($body) = $src =~ /\nsub action_site_backup_upload\b(.*?)(?=\nsub \w)/s;
    ok( defined $body, 'found the action' ) or return;
    like( $body, qr/check_upload_rate\(\s*\$auth_user\s*,\s*length/,
        'check_upload_rate is called with ($auth_user, length ...)' );
    unlike( $body, qr/check_upload_rate\(\s*\$DOCROOT/,
        'and never with the docroot' );
};

done_testing;
