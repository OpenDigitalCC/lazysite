#!/usr/bin/perl
# SM019: unit tests for load_upload_limits and
# is_blocked_upload_target. Writes a throwaway lazysite.conf in a
# temp docroot and loads the API script against it.
use strict;
use warnings;
use Test::More;
use FindBin;
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use lib "$FindBin::Bin/../../lib";
use TestHelper qw(repo_root);

my $docroot = tempdir( CLEANUP => 1 );
make_path("$docroot/lazysite");

BEGIN {
    $ENV{LAZYSITE_API_LOAD_ONLY} = 1;
}
$ENV{DOCUMENT_ROOT} = $docroot;

my $root = repo_root();
{
    package main;
    do "$root/lazysite-manager-api.pl" or die "load failed: $@";
}

sub write_conf {
    my ($body) = @_;
    open my $fh, '>', "$docroot/lazysite/lazysite.conf" or die $!;
    print $fh $body;
    close $fh;
    main::_reset_upload_limits_cache();
}

# --- load_upload_limits ---

subtest 'defaults when no conf file' => sub {
    unlink "$docroot/lazysite/lazysite.conf";
    main::_reset_upload_limits_cache();
    my $l = main::load_upload_limits();
    is( $l->{max_bytes},  10 * 1024 * 1024, 'default max_bytes 10MB' );
    is( $l->{rate_count}, 60,               'default rate_count' );
    is( $l->{rate_bytes}, 500 * 1024 * 1024, 'default rate_bytes 500MB' );
    is_deeply( $l->{blocked_extensions}, [ 'pl', 'cgi' ],
        'default blocked_extensions' );
    ok( scalar @{ $l->{blocked_paths} } >= 3,
        'default blocked_paths non-empty' );
};

subtest 'max_mb parsed' => sub {
    write_conf("manager_upload_max_mb: 25\n");
    my $l = main::load_upload_limits();
    is( $l->{max_bytes}, 25 * 1024 * 1024, 'max_mb honoured' );
};

subtest 'invalid max_mb falls back' => sub {
    write_conf("manager_upload_max_mb: garbage\n");
    my $l = main::load_upload_limits();
    is( $l->{max_bytes}, 10 * 1024 * 1024,
        'invalid max_mb falls back to default' );
};

subtest 'blocked_paths list parsed, slashes trimmed' => sub {
    write_conf("manager_upload_blocked_paths: /foo/, bar, /baz/qux/\n");
    my $l = main::load_upload_limits();
    is_deeply( $l->{blocked_paths}, [ 'foo', 'bar', 'baz/qux' ],
        'paths parsed and trimmed' );
};

subtest 'blocked_extensions list parsed' => sub {
    write_conf("manager_upload_blocked_extensions: PL, CGI, Sh\n");
    my $l = main::load_upload_limits();
    is_deeply( $l->{blocked_extensions}, [ 'pl', 'cgi', 'sh' ],
        'extensions lowercased and parsed' );
};

subtest 'trailing whitespace and empty entries' => sub {
    write_conf("manager_upload_blocked_paths: a,,b ,  , c   \n");
    my $l = main::load_upload_limits();
    is_deeply( $l->{blocked_paths}, [ 'a', 'b', 'c' ],
        'empty and whitespace entries filtered' );
};

# --- is_blocked_upload_target ---

subtest 'blocks configured path prefixes' => sub {
    write_conf("manager_upload_blocked_paths: secret/dir\n"
             . "manager_upload_blocked_extensions:\n");
    ok(  main::is_blocked_upload_target('secret/dir/a.txt'),
        'prefix match blocks' );
    ok(  main::is_blocked_upload_target('secret/dir'),
        'exact match blocks' );
    ok( !main::is_blocked_upload_target('other/dir/a.txt'),
        'non-match passes' );
    ok( !main::is_blocked_upload_target('secret/director'),
        'partial prefix (no /) does not match' );
};

subtest 'blocks configured extensions case-insensitively' => sub {
    write_conf("manager_upload_blocked_paths:\n"
             . "manager_upload_blocked_extensions: exe,bat\n");
    ok(  main::is_blocked_upload_target('foo.exe'), '.exe blocked' );
    ok(  main::is_blocked_upload_target('foo.EXE'), '.EXE blocked (case-insensitive)' );
    ok(  main::is_blocked_upload_target('foo.bat'), '.bat blocked' );
    ok( !main::is_blocked_upload_target('foo.md'),  '.md passes' );
};

subtest 'normal .md file passes' => sub {
    write_conf('');
    ok( !main::is_blocked_upload_target('pages/hello.md'),
        '.md in unblocked dir passes' );
};

done_testing();
