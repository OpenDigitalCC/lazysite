#!/usr/bin/perl
# SM282: an editor cannot check a draft section, because they can see it.
#
# A draft section is invisible to the public and visible to a signed-in editor.
# That is the feature working, and it is exactly why the editor is the one
# person who cannot verify it - everything looks fine from where they are
# standing. The documented answer is a private browsing window, which works and
# means leaving the manager, while the thing being checked is precisely whether
# leaving the manager changes what you see.
#
# THE SAFETY PROPERTY IS THE IDENTITY STRIP, and it is what this test is for. A
# preview that inherits the operator's identity shows them their own view and
# labels it the public's - the same defect wearing the costume of the fix. So
# the fixture calls it WITH operator identity in the environment and asserts the
# answer is the anonymous one.
use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use JSON::PP   qw(encode_json);
use FindBin;
use lib "$FindBin::Bin/../lib";
use lib "$FindBin::Bin/../../lib";
use TestHelper                 qw(setup_test_site);
use Lazysite::Manager::Domains ();

my $docroot = tempdir( CLEANUP => 1 );
setup_test_site($docroot);
$Lazysite::Manager::Domains::DOCROOT = $docroot;

# processor_path() derives the CGI from LAZYSITE_PROCESSOR or a cgi-bin sibling
# of the docroot; a tempdir has neither.
$ENV{LAZYSITE_PROCESSOR} = "$FindBin::Bin/../../lazysite-processor.pl";

make_path("$docroot/zz-draft");
open my $p, '>', "$docroot/zz-draft/index.md" or die $!;
print {$p} "---\ntitle: Draft\n---\n\nDRAFT-BODY-MARKER\n";
close $p;
open my $o, '>', "$docroot/open.md" or die $!;
print {$o} "---\ntitle: Open\n---\n\nOPEN-BODY-MARKER\n";
close $o;

# Gate the section the way an operator would. setup_test_site does not create
# the auth dir, and the first version of this died on the open() rather than
# reporting a fixture problem.
make_path("$docroot/lazysite/auth");
open my $acl, '>', "$docroot/lazysite/auth/acls.json" or die $!;
# `operator` IS on the read list, deliberately. If the list refused everyone,
# the identity subtest below would pass whether or not the strip works - the
# section would be invisible to the operator too, and there would be nothing to
# leak. Sabotaging the strip is what revealed that; the first version of this
# fixture used 'nobody-at-all' and was green with the strip deleted.
print {$acl} encode_json( { 'zz-draft' => { read => ['operator'] } } );
close $acl;

subtest 'a public page previews as visible' => sub {
    my $r = Lazysite::Manager::Domains::preview_public('/open');
    ok( $r->{ok}, 'the preview runs' ) or diag explain $r;
    is( $r->{verdict}, 'visible', 'and reports it visible' );
    like( $r->{excerpt}, qr/OPEN-BODY-MARKER/, 'showing what a visitor gets' );
    like( $r->{note},    qr/WOULD see/,        'in the operator\'s terms' );
};

subtest 'a gated section previews as NOT visible, and that is the check passing'
    => sub {
    my $r = Lazysite::Manager::Domains::preview_public('/zz-draft/');
    ok( $r->{ok}, 'the preview still RUNS - a refusal is a result, not a fault' )
        or diag explain $r;
    isnt( $r->{verdict}, 'visible', 'and the visitor does not see it' );
    is( $r->{public}, JSON::PP::false, 'reported as not public' );
    unlike( $r->{excerpt}, qr/DRAFT-BODY-MARKER/,
        'and the draft body is nowhere in the answer' )
        or diag( 'The preview must never become a way to READ a gated section. '
            . 'It renders anonymously, so this is safe by construction - and '
            . 'asserted, because construction can be edited.' );
    like( $r->{note}, qr/would NOT see|expected result/,
        'and it says a refusal is the expected result rather than an error' );
    };

subtest 'the operator identity does not leak into the render' => sub {
    # THE WHOLE SAFETY PROPERTY. Called with every marker that would make the
    # processor treat the caller as a signed-in operator. If any of them
    # survives, the preview shows the editor their own view and calls it the
    # public's - which is worse than not having the feature.
    local $ENV{LAZYSITE_AUTH_TRUSTED} = '1';
    local $ENV{HTTP_X_REMOTE_USER}    = 'operator';
    local $ENV{HTTP_X_REMOTE_GROUPS}  = 'managers';
    local $ENV{HTTP_COOKIE}           = 'lzs_session=1';

    my $r = Lazysite::Manager::Domains::preview_public('/zz-draft/');
    ok( $r->{ok}, 'it runs' );
    isnt( $r->{verdict}, 'visible',
        'the gated section is STILL not visible - and `operator` is ON its '
            . 'read list, so a leaked identity WOULD have shown it' )
        or diag( 'The identity strip failed. This preview is showing the '
            . "operator's own view and labelling it the public's." );
    unlike( $r->{excerpt}, qr/DRAFT-BODY-MARKER/,
        'and the body still does not appear' );
};

subtest 'a traversal path is refused rather than rendered' => sub {
    for my $bad ( '/../etc/passwd', '/zz-draft/../../etc' ) {
        my $r = Lazysite::Manager::Domains::preview_public($bad);
        ok( !$r->{ok}, "refused: $bad" );
    }
};

done_testing();
