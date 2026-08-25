#!/usr/bin/perl
# SM520: a domain preview renders as the ANONYMOUS visitor, never as the
# operator who asked for it.
#
# preview_public strips HTTP_COOKIE and HTTP_AUTHORIZATION before shelling the
# processor. domain_preview stripped only HTTP_X_REMOTE_* and LAZYSITE_AUTH_*,
# so the operator's session cookie and bearer token rode along into the render
# - and a draft or gated section previewed as visible under the domain check.
# The processor hands HTTP_COOKIE to its front route and cookie reader, so
# forwarding it IS logging in.
#
# The stub processor below echoes its identity-bearing environment and shows a
# gated body only when a session cookie reaches it - the same shape as the
# probe that proved the defect (tmp/tl-probe-preview-cookie.pl).
use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use FindBin;
use lib "$FindBin::Bin/../../lib";
use lib "$FindBin::Bin/../../../lib";
use Lazysite::Manager::Domains ();

my $root = tempdir( CLEANUP => 1 );
my $doc  = "$root/site";
make_path( "$doc/lazysite", "$doc/a" );

sub _w {
    my ( $p, $c ) = @_;
    open my $f, '>', $p or die "$p: $!";
    print {$f} $c;
    close $f;
    return;
}

_w( "$doc/lazysite/lazysite.conf",
    "site_url: https://primary.example.com\n"
        . "alias_hosts: a.example.com\n"
        . "alias.a.example.com.content_root: a\n" );

my $stub = "$root/stub-processor.pl";
_w( $stub, <<'EOS' );
print "Status: 200\r\n\r\n";
for my $k (qw(HTTP_COOKIE HTTP_AUTHORIZATION HTTP_X_REMOTE_USER LAZYSITE_AUTH_TOKEN HTTP_HOST)) {
    print "$k=", ( exists $ENV{$k} ? $ENV{$k} : '<stripped>' ), "\n";
}
my $c = $ENV{HTTP_COOKIE} // '';
print( ( $c =~ /lzs_session=/ ? 'DRAFT-BODY-MARKER' : 'GATED-REFUSAL' ), "\n" );
EOS

{
    no warnings 'redefine';
    *Lazysite::Manager::Domains::processor_path = sub { $stub };
}
$Lazysite::Manager::Domains::DOCROOT = $doc;

local $ENV{HTTP_COOKIE}         = 'lzs_session=SECRET';
local $ENV{HTTP_AUTHORIZATION}  = 'Bearer SECRET';
local $ENV{HTTP_X_REMOTE_USER}  = 'operator';
local $ENV{LAZYSITE_AUTH_TOKEN} = 'tok';
local $ENV{HTTP_HOST}           = 'manager.example.com';

subtest 'domain_preview renders as nobody' => sub {
    my $d = Lazysite::Manager::Domains::domain_preview('a.example.com');
    ok( $d->{ok}, 'the preview runs' ) or diag explain $d;
    unlike( $d->{html}, qr/lzs_session=/,
        'the operator session cookie does not reach the processor' )
        or diag( 'With the cookie forwarded the processor IS logged in as the '
            . 'operator, and the domain check shows their view as the public\'s.' );
    unlike( $d->{html}, qr/Bearer SECRET/,
        'nor does the Authorization header' );
    unlike( $d->{html}, qr/DRAFT-BODY-MARKER/,
        'so a gated body is nowhere in the answer' );
    like( $d->{html}, qr/GATED-REFUSAL/, 'the visitor gets the refusal' );
    like( $d->{html}, qr/HTTP_X_REMOTE_USER=<stripped>/,
        'the pre-existing strip of HTTP_X_REMOTE_* still holds' );
    like( $d->{html}, qr/LAZYSITE_AUTH_TOKEN=<stripped>/,
        'and of LAZYSITE_AUTH_*' );
    like( $d->{html}, qr/HTTP_HOST=a\.example\.com/,
        'while the domain Host is still supplied' );
};

subtest 'preview_public, the twin, strips the same set' => sub {
    my $p = Lazysite::Manager::Domains::preview_public('/a/');
    ok( $p->{ok}, 'the preview runs' ) or diag explain $p;
    unlike( $p->{excerpt}, qr/lzs_session=|Bearer SECRET|DRAFT-BODY-MARKER/,
        'no identity reaches the processor' );
    like( $p->{excerpt}, qr/HTTP_HOST=a\.example\.com/,
        'rendered under the owning host' );
};

subtest 'the two previews share one environment builder' => sub {
    my $src = do {
        open my $fh, '<', "$FindBin::Bin/../../../lib/Lazysite/Manager/Domains.pm"
            or die $!;
        local $/;
        <$fh>;
    };
    my @calls = $src =~ /^\s*_anonymous_env\(\);/mg;
    is( scalar @calls, 2, 'both previews call _anonymous_env()' )
        or diag( 'Two hand-written strip lists drifted once (SM520). '
            . 'One helper is how they stop drifting.' );
};

done_testing();
