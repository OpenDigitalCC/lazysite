#!/usr/bin/perl
# SM747 C (OT1, OT2, OI4, OI5), through the real render path - the processor run
# as the CGI it is:
#
#   tt_page_var:
#     me: odoo-identity:
#
# * the page can greet the viewer by the name Odoo gave, and show or hide a part
#   of itself by their groups - PRESENTATION: nothing here permits anything;
# * a viewer with no cookie, an ended one, or one that does not verify sees the
#   page as though nobody had signed in - a tampered identity is no identity;
# * every value is escaped as a `db:` value is;
# * THE CACHE, FAIL-CLOSED, by SM857's own mechanism: such a page is never read
#   from or written to the shared page cache and is no-store on output - so one
#   person's greeting is never served to the next - and a binding the peek did
#   not see (a variable outside the page's own front matter) is REFUSED rather
#   than rendered, because what it read could be cached for everyone.
use strict;
use warnings;
use Test::More;
use File::Path qw(make_path);
use FindBin;
use lib "$FindBin::Bin/../../lib", "$FindBin::Bin/../../../lib";
use TestHelper qw(setup_test_site site_tempdir processor_path load_processor);

use Lazysite::Odoo::Identity ();
use Lazysite::Odoo::Visitor  ();

sub spit { my ( $p, $t ) = @_; open my $fh, '>', $p or die "$p: $!"; print {$fh} $t; close $fh; return }

sub slurp {
    my ($p) = @_;
    open my $fh, '<', $p or return '';
    local $/;
    my $t = <$fh>;
    close $fh;
    return $t;
}

my $docroot = site_tempdir();
setup_test_site($docroot);
{
    no warnings 'once';
    $Lazysite::Odoo::Visitor::DOCROOT = $docroot;
}

# WITH A ttl:, which is the shape that leaks: a page with a ttl: is served from
# the cache for that long, to whoever asks next.
spit( "$docroot/me.md",
    "---\ntitle: Me\nttl: 300\ntt_page_var:\n  me: odoo-identity:\n---\n"
        . "Hello [% me.name %]|lang=[% me.lang %]|tz=[% me.tz %]|co=[% me.company_id %]"
        . "[% IF me.groups.size %]|groups=[% me.groups.join(',') %][% END %]\n" );
spit( "$docroot/plain.md", "---\ntitle: Plain\nttl: 300\n---\nPLAIN-PAGE\n" );

my $logfile = "$docroot/../render.log";

sub render {
    my ( $uri, %as ) = @_;
    local %ENV = %ENV;
    delete $ENV{$_} for grep { /\AHTTP_X_REMOTE_|\ALAZYSITE_|\AHTTP_COOKIE\z/ } keys %ENV;
    $ENV{DOCUMENT_ROOT}      = $docroot;
    $ENV{REDIRECT_URL}       = $uri;
    $ENV{REQUEST_METHOD}     = 'GET';
    $ENV{QUERY_STRING}       = '';
    $ENV{LAZYSITE_LOG_LEVEL} = 'INFO';
    $ENV{HTTP_COOKIE}        = $as{cookie} if defined $as{cookie};
    unlink $logfile;
    my $proc = processor_path();
    my $out  = qx($^X \Q$proc\E 2>\Q$logfile\E);
    return ( $out, slurp($logfile) );
}

my $JANE = Lazysite::Odoo::Identity::mint_cookie(
    { name => 'Jane <i>Doe</i>', lang => 'en_GB', tz => 'Europe/London', company_id => 4, company_ids => [ 4, 5 ],
        groups => [ 'Sales', 'Stock' ] } );
my $JC = "lzs_odoo_identity=$JANE";

# --- THE CANARY ----------------------------------------------------------------
# An ordinary page IS cached here, so the absence of the identity page's cache
# file below is a finding, not a fixture that caches nothing.
{
    my ($out) = render('/plain');
    like( $out, qr/PLAIN-PAGE/, 'canary: an ordinary page renders' );
    ok( -f "$docroot/plain.html", 'canary: and is written to the page cache' );
}

subtest 'the viewer is greeted by what Odoo said, escaped' => sub {
    my ($out) = render( '/me', cookie => $JC );
    like( $out, qr/Hello Jane &lt;i&gt;Doe&lt;\/i&gt;\|/, 'the name, escaped' );
    unlike( $out, qr/<i>Doe/, 'no markup from Odoo survives' );
    like( $out, qr/lang=en_GB\|tz=Europe\/London\|co=4/, 'language, time zone, company' );
    like( $out, qr/groups=Sales,Stock/, 'and the groups, for a page to show or hide a section by' );
};

subtest 'no cookie, an ended one, a tampered one: the page as though nobody had signed in' => sub {
    my ($anon) = render('/me');
    like( $anon, qr/Hello \|lang=\|tz=\|co=<\/p>/, 'no cookie: nothing' );
    unlike( $anon, qr/Jane/, '...and not the name' );
    my $old = Lazysite::Odoo::Identity::mint_cookie( { name => 'Jane' }, now => time - 5000 );
    my ($ended) = render( '/me', cookie => "lzs_odoo_identity=$old" );
    unlike( $ended, qr/Jane/, 'an ended cookie: no name' );
    ( my $t = $JANE ) =~ s/\A(.)/$1 eq 'e' ? 'f' : 'e'/e;
    my ($bad) = render( '/me', cookie => "lzs_odoo_identity=$t" );
    unlike( $bad, qr/Jane/, 'an edited cookie: no name' );
    my ($b2) = render( '/me', cookie => "lzs_odoo_identity=$JANE.extra" );
    unlike( $b2, qr/Jane/, 'a malformed one: no name' );
    my $session_like = "lzs_odoo_identity=" . join( '.', 'abcdefghij', time, 'f' x 64 );
    my ($forged) = render( '/me', cookie => $session_like );
    unlike( $forged, qr/abcdefghij|Hello [A-Za-z]/, 'one with a made-up signature: no name' );
};

subtest 'the cache: never read, never written, no-store - one person\'s greeting is not the next\'s' => sub {
    unlink "$docroot/me.html";
    my ($a) = render( '/me', cookie => $JC );
    ok( !-f "$docroot/me.html", 'the identity page is not written to the page cache' );
    like( $a, qr/^Cache-Control:[^\n]*no-store/mi, 'and is no-store on output' );
    my ($b) = render('/me');
    unlike( $b, qr/Jane/, 'the next viewer is not served the first one\'s page' );
    like( $b, qr/Hello \|/, '...they get their own render' );
    my ($c) = render( '/me', cookie => $JC );
    like( $c, qr/Hello Jane/, 'and the first, again, still gets theirs' );
};

subtest 'a binding outside the page\'s own front matter is refused, not cached' => sub {
    load_processor($docroot);
    no warnings 'once';
    local %main::RENDER_QUERY = ();    # a render the per-viewer mark did not reach
    local $ENV{HTTP_COOKIE} = $JC;
    my ( %v, $log );
    {
        open my $fh, '>', \$log or die $!;
        local *STDERR = $fh;
        %v = main::resolve_tt_vars( { me => 'odoo-identity:' } );
    }
    is_deeply( $v{me}, {}, 'it renders as nobody' );
    like( $log, qr/odoo-identity: binding refused.*cached and served to another viewer/, 'and the log says why' );
};

done_testing();
