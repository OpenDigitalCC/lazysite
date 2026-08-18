#!/usr/bin/perl
# SM364: the state, reached at last, and it says the listing is right.
#
# The report was that a Depth 1 PROPFIND on a themes/ collection enumerates
# dot-prefixed entries which PROPFIND, GET and DELETE all refuse - a client that
# can see them, cannot fetch them and cannot remove them.
#
# THREE ATTEMPTS FAILED TO REACH THAT STATE, each for a reason unrelated to the
# question, so this test exists as much to pin the STATE as the behaviour. What
# reaches it:
#
#   HTTPS=on                        or the transport gate refuses everything
#                                   with "HTTPS required" - which is what made
#                                   attempt three look like a capability
#                                   problem and sent it after the wrong thing
#   manage_themes + manage_layouts  or authorise_layout refuses the whole
#                                   subtree before any path logic runs
#
# Neither is exotic. Both are invisible in a failure that says 403, which is why
# three fixtures in a row measured something other than what they meant to.
#
# AND THE ANSWER INVERTS THE FILING. With that state reached, the dot-prefixed
# entry is listed, READ and DELETED successfully. The engine has no dot-prefix
# policy in this subtree, its verbs allow the entry, and the listing agrees with
# them. So filtering dot entries from the listing - the obvious fix - would hide
# something fully addressable, which is the defect pointing the other way.
#
# This test is therefore a guard against the fix that was nearly written.
use strict;
use warnings;
use Test::More;
use File::Path qw(make_path);
use FindBin;
use lib "$FindBin::Bin/../lib";
use TestHelper qw(setup_dav_site);

my $site = setup_dav_site(
    caps => [
        qw(webdav manage_content manage_nav manage_forms
            manage_themes manage_layouts)
    ]
);
my $d = $site->{docroot};

make_path("$d/lazysite/layouts/base/themes/plain");
for my $f (
    [ "$d/lazysite/layouts/base/layout.tt",               '[% content %]' ],
    [ "$d/lazysite/layouts/base/themes/plain/theme.json", '{"name":"plain"}' ],
    [ "$d/lazysite/layouts/base/themes/.pristine-plain",  "baseline\n" ],
    [ "$d/lazysite/layouts/base/themes/visible.css",      "body{}\n" ],
    )
{
    open my $fh, '>', $f->[0] or die $!;
    print {$fh} $f->[1];
    close $fh;
}

sub dav {
    my ( $method, $path ) = @_;
    local %ENV = %ENV;
    $ENV{DOCUMENT_ROOT}      = $d;
    $ENV{REQUEST_METHOD}     = $method;
    $ENV{PATH_INFO}          = $path;
    $ENV{HTTPS}              = 'on';
    $ENV{HTTP_AUTHORIZATION} = $site->{auth};
    $ENV{HTTP_DEPTH}         = '1';
    $ENV{CONTENT_LENGTH}     = 0;
    my $root     = "$FindBin::Bin/../..";
    my $out      = qx($^X \Q$root/lazysite-dav.pl\E 2>&1);
    my ($status) = $out =~ /Status:\s*(\d+)/;
    return ( $status // '?', $out );
}

subtest 'the listing enumerates the dot-prefixed entry' => sub {
    my ( $status, $out ) = dav( 'PROPFIND', '/lazysite/layouts/base/themes' );
    is( $status, '207', 'the collection lists' ) or diag substr( $out, 0, 300 );
    like( $out, qr/\.pristine-plain/, 'and includes the marker' );
    like( $out, qr/visible\.css/,     'alongside an ordinary file' );
};

subtest 'and every verb can address what was listed' => sub {
    # THE WHOLE FINDING. If any of these refuses while the listing shows the
    # entry, SM364 is real and the listing needs the verbs' predicate. They do
    # not refuse - so the listing is right and the fix is elsewhere.
    my ($get_dot) = dav( 'GET', '/lazysite/layouts/base/themes/.pristine-plain' );
    is( $get_dot, '200', 'GET on the dot-prefixed entry succeeds' )
        or diag( 'If this is a refusal, the listing is offering something no '
            . 'verb can reach and SM364 is an engine defect after all.' );

    my ($get_plain) = dav( 'GET', '/lazysite/layouts/base/themes/visible.css' );
    is( $get_plain, '200', 'and so does GET on the ordinary file' )
        or diag( 'The control. A refusal here means the fixture is measuring '
            . 'something else - which is how three earlier attempts went.' );

    my ($del) = dav( 'DELETE', '/lazysite/layouts/base/themes/.pristine-plain' );
    is( $del, '204', 'DELETE removes it' )
        or diag( 'The residue an operator could not clear is removable at the '
            . 'engine. If it is not removable through their front end, that is '
            . 'a different system.' );
    ok( !-f "$d/lazysite/layouts/base/themes/.pristine-plain",
        'and it is gone from disk' );
};

subtest 'so a dot-prefix filter on the listing would HIDE an addressable entry'
    => sub {
    # Recorded as a test rather than a comment, because "filter the dot
    # entries" is a one-line change that looks obviously right and would be a
    # defect: it would remove from the listing something GET and DELETE both
    # serve. Whoever revisits this should have to delete this subtest first.
    open my $fh, '>', "$d/lazysite/layouts/base/themes/.pristine-plain" or die $!;
    print {$fh} "baseline\n";
    close $fh;

    my ( undef, $out ) = dav( 'PROPFIND', '/lazysite/layouts/base/themes' );
    my ($listed) = $out =~ /\.pristine-plain/ ? 1 : 0;
    my ($get)    = dav( 'GET', '/lazysite/layouts/base/themes/.pristine-plain' );
    is( $listed, 1,     'the entry is listed' );
    is( $get,    '200', 'and fetchable - so listing it is CORRECT' );
    };

done_testing();
