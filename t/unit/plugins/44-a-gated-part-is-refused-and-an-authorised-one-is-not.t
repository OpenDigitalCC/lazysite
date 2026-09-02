#!/usr/bin/perl
# SM739: the two-reader fixture the field pass asked for.
#
# WHY IT HAD TO BE TWO. SM706's refusal - "refused rather than built without
# that part" - had never executed once in its life. The existence check looked
# only where a PUBLIC file lives, so a gated part was reported missing before
# may_read was ever consulted, and the protective outcome for a denied reader
# held only by accident. SM738 fixed the order; the edge agent then proved both
# halves on a real server and recommended this be permanent.
#
# ONE READER IS NOT ENOUGH, which is the point of the file. Testing only the
# denied reader passes just as well when the part is invisible to everybody -
# which is exactly the state that hid the bug for a release. The authorised
# reader is what distinguishes "refused because you may not" from "missing".
use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use FindBin;
use lib "$FindBin::Bin/../../lib";
use lib "$FindBin::Bin/../../../lib";

my $plugin = "$FindBin::Bin/../../../plugins/pandoc.pl";
plan skip_all => 'the plugin is not present' unless -f $plugin;

# Loaded, not run: `run(@ARGV) unless caller` guards its entry point.
do $plugin;
my $convert = main->can('convert')
    or plan skip_all => 'the converter is not exposed';

my $root = tempdir( CLEANUP => 1 );
make_path("$root/pages");
make_path("$root/private/pages");    # where a read ACL puts content

my $write = sub {
    my ( $path, $body ) = @_;
    open my $fh, '>', "$root/$path" or die "$path: $!";
    print {$fh} $body;
    close $fh;
};

$write->( 'pages/whole.md',  "---\ntitle: Whole\nparts:\n  - pages/open.md\n  - pages/gated.md\n---\n\nBody.\n" );
$write->( 'pages/open.md',   "---\ntitle: Open\n---\n\nOpen body.\n" );
# The gated part lives ONLY in the private store - which is what a read ACL
# does to a file, and what the old docroot-only check could not see.
$write->( 'private/pages/gated.md', "---\ntitle: Gated\n---\n\nGated body.\n" );

# The caller answers both questions, exactly as the manager API does.
my $resolve = sub {
    my ($rel) = @_;
    return "$root/private/$rel" if -f "$root/private/$rel";
    return "$root/$rel"         if -f "$root/$rel";
    return undef;
};

subtest 'a part in the private store is FOUND, not reported missing' => sub {
    # The regression this guards: before SM738 this returned "no such part",
    # to everyone, because it looked only in the docroot.
    my $r = $convert->(
        docroot  => $root,
        path     => 'pages/whole.md',
        resolve  => $resolve,
        may_read => sub { 1 },
    );
    ok( ref $r eq 'HASH', 'the converter answered' ) or return;
    unlike( $r->{error} // '', qr/no such part/,
        'an authorised reader is NOT told the gated part is missing' );
};

subtest 'the denied reader gets the refusal, naming the part' => sub {
    my $r = $convert->(
        docroot  => $root,
        path     => 'pages/whole.md',
        resolve  => $resolve,
        may_read => sub { $_[0] !~ /gated/ },
    );
    ok( ref $r eq 'HASH', 'the converter answered' ) or return;
    ok( !$r->{ok}, 'it is refused' );
    like( $r->{error} // '', qr/pages\/gated\.md/, 'and the part is named' );
    like( $r->{error} // '', qr/refused rather than built without/,
        'in the SM706 wording - not "no such part", which is what it used to say' );
};

subtest 'a part that genuinely does not exist is still missing' => sub {
    # The refusal must not swallow a real absence: "you may not read it" and
    # "it is not there" are different answers and must stay different.
    $write->( 'pages/broken.md', "---\ntitle: Broken\nparts:\n  - pages/nope.md\n---\n\nB.\n" );
    my $r = $convert->(
        docroot  => $root,
        path     => 'pages/broken.md',
        resolve  => $resolve,
        may_read => sub { 1 },
    );
    ok( !$r->{ok}, 'refused' );
    like( $r->{error} // '', qr/no such part/, 'and correctly as MISSING' );
};

done_testing();
