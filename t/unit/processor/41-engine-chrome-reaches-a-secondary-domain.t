#!/usr/bin/perl
# SM382: the engine's own assets must resolve on a content-rooted domain.
#
# SM352 moved the engine's chrome out of inline blocks and into
# /assets/lazysite-chrome.{css,js}, which ship into the DOCROOT. Static
# resolution is content-root scoped (SM151) and refuses anything outside that
# root, so on a secondary domain with its own content_root the bundle 404s.
#
# WHAT BREAKS, and why nothing reports it: the frame suppression, the SM099
# auth-control sync, and the form submit and multi-step handling all live in
# that script. It simply never loads. There is no error on the page, no entry in
# the log the operator reads, and the site otherwise renders perfectly.
#
# THE FIXTURE HAS TO PROVE ITS OWN CONDITION. An alias content root only applies
# when the host is declared in alias_hosts, and three earlier versions of this
# fixture silently ran everything against the PRIMARY root - returning 200/200
# and looking like an absence of defect. The control subtest below is the reason
# the result can be believed.
use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use FindBin;
use lib "$FindBin::Bin/../../lib";
use TestHelper qw(setup_test_site run_processor);

my $docroot = tempdir( CLEANUP => 1 );
setup_test_site($docroot);

# SM223: the engine only serves statics when the site HAS an ACL store -
# otherwise the front end answers them and the engine never sees the request.
# Without this the fixture 404s on both roots and proves nothing.
make_path("$docroot/lazysite/auth");
open my $acl, '>', "$docroot/lazysite/auth/acls.json" or die $!;
print {$acl} "{}\n";
close $acl;

make_path("$docroot/assets");
open my $js, '>', "$docroot/assets/lazysite-chrome.js" or die $!;
print {$js} "/* engine chrome */\n";
close $js;

# A secondary domain with its own content root, and a page only IT has.
make_path("$docroot/sites/secondary");
open my $idx, '>', "$docroot/sites/secondary/index.md" or die $!;
print {$idx} "---\ntitle: Second\n---\n\nSECONDARY-ONLY-MARKER\n";
close $idx;

my $conf = "$docroot/lazysite/lazysite.conf";
open my $cf, '<', $conf or die $!;
my @lines = <$cf>;
close $cf;
open my $wf, '>', $conf or die $!;
print {$wf} @lines;
print {$wf} "alias_hosts: secondary.test\n";
print {$wf} "alias.secondary.test.content_root: sites/secondary\n";
close $wf;

sub status_of {
    my ( $uri, $host ) = @_;
    local $ENV{HTTP_HOST} = $host if defined $host;
    my $out = run_processor( $docroot, $uri );
    my ($code) = $out =~ /^Status:\s*(\d+)/mi;
    return ( $code // 0, $out );
}

subtest 'the fixture really does put the secondary on its own root' => sub {
    # Without this, everything below runs against the primary and passes for a
    # reason that has nothing to do with the defect.
    my ( undef, $out ) = status_of( '/', 'secondary.test' );
    like( $out, qr/SECONDARY-ONLY-MARKER/,
        'the secondary domain serves its own content root' )
        or diag( 'An alias content root applies only when the host is declared '
            . 'in alias_hosts. If that is missing the request is served from '
            . 'the primary and every assertion below is vacuous.' );
};

subtest 'the engine chrome resolves on both roots' => sub {
    my ($primary) = status_of('/assets/lazysite-chrome.js');
    is( $primary, 200, 'the primary docroot serves it' );

    my ($secondary) = status_of( '/assets/lazysite-chrome.js', 'secondary.test' );
    is( $secondary, 200, 'and so does a content-rooted secondary domain' )
        or diag( 'A 404 here means the frame suppression, the auth-control '
            . 'sync and the form handling silently stop on every secondary '
            . 'domain - with nothing on the page or in the log to say so.' );
};

subtest 'and the exemption is not a way out of the content root' => sub {
    # The narrow point. This must not become a general fallback to the docroot:
    # content-root confinement is what SM151 exists to enforce, and a secondary
    # domain reaching a sibling's files would be a far worse defect than the one
    # being fixed.
    open my $secret, '>', "$docroot/assets/primary-only.txt" or die $!;
    print {$secret} "PRIMARY-ONLY-CONTENT\n";
    close $secret;

    my ( $code, $out ) = status_of( '/assets/primary-only.txt', 'secondary.test' );
    unlike( $out, qr/PRIMARY-ONLY-CONTENT/,
        'a non-engine file in the primary is NOT served to a secondary domain' )
        or diag( 'The exemption is meant to be an explicit list of engine-owned '
            . 'paths. If it has become a prefix or a general fallback, a '
            . 'content-rooted domain can now read its siblings.' );
    isnt( $code, 200, 'and it is not answered 200' );
};

done_testing();
