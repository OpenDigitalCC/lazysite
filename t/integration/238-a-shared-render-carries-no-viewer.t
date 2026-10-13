#!/usr/bin/perl
# SM1068: the shared page cache holds a render made for NOBODY.
#
# The template stash carries the viewer - authenticated, auth_user, editor - and
# a layout that prints one bakes it into the render. Measured on main before
# this change, on a page with no rule at all: signed in as alice, then
# anonymous, and the anonymous visitor was handed "WHO=alice EDITOR=1" from the
# cache. A write-only rule used to keep its pages out of the cache, so the
# ruling that makes them cacheable would have put the gap on exactly the pages
# whose first viewer is most often their author.
#
# The shipped chrome already avoids it (SM099's client-toggled auth_control, the
# admin bar injected per response); this holds for a layout that does not.
use strict;
use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/../lib";
use TestHelper qw(setup_auth_site site_tempdir run_processor);

sub put { my ( $p, $c ) = @_; open my $fh, '>', $p or die "$p: $!"; print {$fh} $c; close $fh; return }

for my $case (
    [ 'a page no rule names',           '{}' ],
    [ 'a page under a write-only rule', '{"/":{"owner":"root","write":["@admins"]},'
            . '"page.md":{"owner":"alice","write":["alice"]}}' ],
    )
{
    my ( $what, $rules ) = @$case;
    subtest $what => sub {
        my $d = site_tempdir();
        setup_auth_site($d);
        put( "$d/lazysite/layouts/test/layout.tt",
            '<html><body>[% IF authenticated %]WHO=[% auth_user %][% END %] '
                . 'EDITOR=[% editor %] [% content %]</body></html>' );
        put( "$d/page.md",                 "---\ntitle: P\n---\nBODY-1068\n" );
        put( "$d/lazysite/auth/acls.json", $rules );

        my $signed = run_processor( $d, '/page', HTTP_X_REMOTE_USER => 'alice', HTTP_X_REMOTE_GROUPS => 'admins' );
        like( $signed, qr/WHO=alice/, 'the signed-in viewer sees their own render' );
        ok( !-f "$d/page.html", 'and it is not written to the shared cache' );

        my $anon = run_processor( $d, '/page' );
        like( $anon, qr/BODY-1068/, 'the anonymous visitor is served the page' );
        unlike( $anon, qr/WHO=alice/, 'without the earlier viewer in it' );
        like( $anon, qr/EDITOR=0/, 'or their editor flag' );
        ok( -f "$d/page.html", 'and THAT render fills the cache' );

        my $again = run_processor( $d, '/page', HTTP_X_REMOTE_USER => 'bob', HTTP_X_REMOTE_GROUPS => 'members' );
        unlike( $again, qr/WHO=alice/, 'a second signed-in viewer never sees the first' );
    };
}

done_testing();
