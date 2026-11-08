#!/usr/bin/perl
# SM1352, SM1363 (ruling 187): CryptX is a Recommends, lazy-required only by
# passkeys and web push. `lazysite check` says once for the site what its absence
# costs:
#   - installed: OK, and says the two features can be used
#   - absent, and nothing on the site uses them: OK, saying they are unavailable
#   - absent, and an account holds a passkey or notify.conf routes by webpush: WARN,
#     naming which, with the package to install
# CryptX is hidden from the child by a shadow Crypt/PK/ECC.pm that refuses to load,
# first on PERL5LIB, so the test runs the same on a host that has it.
use strict;
use warnings;
use Test::More;
use File::Path qw(make_path);
use File::Temp qw(tempdir);
use JSON::PP   qw(encode_json);
use FindBin;
use lib "$FindBin::Bin/../../lib";
use TestHelper qw(repo_root site_tempdir run_child);

my $tool = repo_root() . '/tools/lazysite-check.pl';
plan skip_all => "no $tool" unless -f $tool;

my $shadow = tempdir( CLEANUP => 1 );
make_path("$shadow/Crypt/PK");
{
    open my $fh, '>', "$shadow/Crypt/PK/ECC.pm" or die $!;
    print {$fh} "die qq{CryptX is not installed (test shadow)\\n};\n";
    close $fh;
}

sub site {
    my (%o) = @_;
    my $d = site_tempdir();
    make_path("$d/lazysite/auth");
    open my $fh, '>', "$d/lazysite/lazysite.conf" or die $!;
    print {$fh} "site_name: T\n";
    close $fh;
    if ( $o{passkey} ) {
        open my $s, '>', "$d/lazysite/auth/user-settings.json" or die $!;
        print {$s} encode_json( { alice => { passkeys => [ { id => 'AAAA', key => 'BBBB', alg => -7 } ] } } );
        close $s;
    }
    if ( $o{webpush} ) {
        open my $n, '>', "$d/lazysite/notify.conf" or die $!;
        print {$n} "route.submission: bell,webpush\n";
        close $n;
    }
    return $d;
}

sub run {
    my ( $d, %o ) = @_;
    local %ENV = %ENV;
    $ENV{PERL5LIB} = join ':', $shadow, ( length( $ENV{PERL5LIB} // '' ) ? $ENV{PERL5LIB} : () )
        if $o{hidden};
    my $out = run_child( [ $^X, $tool, '--docroot', $d ], stderr => 'inherit' )->{out} // '';
    return join "\n", grep { /CryptX|libcryptx/ } split /\n/, $out;
}

SKIP: {
    skip 'CryptX is not installed on this host', 1 unless eval { require Crypt::PK::ECC; 1 };
    like( run( site() ), qr/CryptX is installed: passkeys and web push can be used/,
        'installed: the check says the two features can be used' );
}

my $plain = run( site(), hidden => 1 );
like( $plain, qr/not installed: passkeys and web push are unavailable until it is/,
    'absent and unused: the check says what is unavailable' );
unlike( $plain, qr/\[ warn \]/i, 'absent and unused: not a warning' );

my $pk = run( site( passkey => 1 ), hidden => 1 );
like( $pk, qr/libcryptx-perl\).*do not work.*an account holds a passkey/,
    'absent and an account holds a passkey: the check names it' );
like( $pk, qr/apt install libcryptx-perl/, 'and says what to install' );

my $wp = run( site( webpush => 1 ), hidden => 1 );
like( $wp, qr/notify\.conf routes a notice by webpush/, 'absent and a webpush route: the check names it' );

done_testing();
